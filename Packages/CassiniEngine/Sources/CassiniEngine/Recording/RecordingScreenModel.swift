import Foundation
import Observation
import CassiniNotebook

/// Where the Recording screen's capture is.
public enum RecordingPhase: Hashable, Sendable {
    case needsPermission, starting, recording, paused, stopping
}

/// What the Recording screen asks the app to do.
public enum RecordingEffect: Hashable, Sendable {
    /// Back to the Library; the recording continues.
    case close
    /// Cassini's page in the Settings app (microphone access is off).
    case openSettings
    /// Replace the Recording screen with the note, and the model download on top when `modelDownload`.
    case openNote(UUID, modelDownload: Bool)
    /// Show the Recording screen: a recording stopped on its own and its banner says why.
    case show
}

/// The Recording screen. The recording itself is `RecordingController`'s; this model starts it on entry once the
/// microphone is allowed, shows its state, levels and banners, and leads away when it ends.
///
/// - Entry with microphone access starts the capture; without it the system is asked, and a denial shows "Microphone
///   access is off". The capture then starts when the app comes back with access granted.
/// - Entry while a recording is in progress shows it.
/// - Finish: a saved recording opens its note, with the model download on top when consent was never asked and the
///   speech model is missing. A storage stop, a microphone failure and a failed start stay with their banner.
/// - The model lives as long as the app, and the screen is shown again in many ways (the Library's card, the Live
///   Activity, an automatic stop). Each showing leads away at most once: `appeared()` (and `enter()`) start a new one.
///   Leading away also drops a start that was waiting for microphone access, so it never begins off screen.
/// - The end of a recording is handled in the turn it is told: the banner, the phase and `.show` change together. Only
///   the speech-model lookup of a saved finish waits, and it leads away only if nothing newer began meanwhile.
@MainActor @Observable
public final class RecordingScreenModel {
    public struct Ports {
        public var permission: any MicrophonePermission
        /// Whether a part of the speech model is missing, so finishing without consent opens the model download.
        public var modelsMissing: @MainActor () async -> Bool
        /// Asked once, at the first recording, for permission to tell about recordings that stopped on their own.
        public var notifier: (any Notifier)?
        public var settings: SettingsStore

        public init(permission: any MicrophonePermission, modelsMissing: @escaping @MainActor () async -> Bool,
                    notifier: (any Notifier)?, settings: SettingsStore) {
            self.permission = permission; self.modelsMissing = modelsMissing; self.notifier = notifier; self.settings = settings
        }
    }

    /// A recording that ended without being saved by the user; the screen keeps its banner.
    public struct Ended: Hashable, Sendable {
        public var outcome: RecordingOutcome
        /// The note that keeps what was captured; nil when nothing was kept.
        public var noteID: UUID?
    }

    public let controller: RecordingController
    public private(set) var microphoneDenied = false
    /// Waiting for microphone access to start.
    public private(set) var pendingStart = false
    public private(set) var ended: Ended?
    /// The capture as last shown, for the title and time while it is being saved.
    private var shown: ActiveRecording?

    @ObservationIgnored public var onEffect: (@MainActor (RecordingEffect) -> Void)?
    @ObservationIgnored private let ports: Ports
    /// A capture began while this screen was in use: only then does its end lead away.
    @ObservationIgnored private var sawCapture = false
    /// This showing of the screen has already led away; nothing more until it is shown again.
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var prefilled: UUID?
    /// Counts the showings and starts; a deferred lead-away belongs to the one it was made in.
    @ObservationIgnored private var generation = 0

    public init(controller: RecordingController, ports: Ports) {
        self.controller = controller
        self.ports = ports
        controller.observe { [weak self] state in self?.follow(state) }
    }

    // MARK: What the screen shows

    public var phase: RecordingPhase {
        let recorder = controller.state
        let idle = !recorder.inProgress
        if idle, microphoneDenied || pendingStart { return .needsPermission }
        switch idle ? endedOutcome : nil {
        case .couldNotStart: return .starting
        case .stoppedForSpace, .microphoneFailed: return .stopping
        case .saved, nil: break
        }
        switch recorder {
        case .active(let active): return active.pause == nil ? .recording : .paused
        case .finishing, .ended: return .stopping
        case .idle, .starting: return .starting
        }
    }

    public var title: String {
        switch controller.state {
        case .active(let active): active.title
        case .starting: controller.startingTitle ?? ""
        case .finishing: shown?.title ?? ""
        case .idle, .ended: ""
        }
    }

    public var elapsed: TimeInterval {
        if let active = controller.state.activeRecording { return active.elapsed }
        return controller.state.inProgress || ended != nil ? shown?.elapsed ?? 0 : 0
    }

    public var format: CaptureFormat { controller.state.activeRecording?.format ?? shown?.format ?? .pcm48kMono }

    /// The free space as recording time, for the hint; nil before the capture runs.
    public var space: RecordingSpace? { controller.state.activeRecording?.space }

    public var levels: [Float] { controller.bars.levels }

    public var banner: RecordingBanner? {
        RecordingBanner.banners(state: controller.state, microphoneOff: microphoneDenied && !controller.state.inProgress,
                                ended: endedOutcome).first
    }

    /// The outcome the screen shows: the one it kept, or the recorder's before the screen has taken it.
    private var endedOutcome: RecordingOutcome? {
        if let ended { return ended.outcome }
        if case .ended(_, let outcome) = controller.state { return outcome }
        return nil
    }

    // MARK: Entry and permission

    /// The screen is shown, however it was brought up: it may lead away again.
    public func appeared() {
        leaving = false
        generation += 1
    }

    /// The screen is shown to record: starts a recording unless one is in progress, asking for the microphone first.
    public func enter() async {
        appeared()
        guard !controller.state.inProgress else { return }
        if ports.permission.access == .granted {
            startCapture()
        } else {
            pendingStart = true
            permissionAnswered(granted: await ports.permission.request())
        }
        if !ports.settings.notificationsAsked, let notifier = ports.notifier {
            ports.settings.markNotificationsAsked()
            await notifier.requestOnce()
        }
    }

    /// The answer to the system's microphone question.
    public func permissionAnswered(granted: Bool) {
        guard pendingStart else { return }
        if granted { startCapture() } else { microphoneDenied = true }
    }

    /// The app is active again, maybe back from Settings with access granted.
    public func appBecameActive() {
        if ports.permission.access == .granted, pendingStart, !controller.state.inProgress { startCapture() }
    }

    private func startCapture() {
        generation += 1
        pendingStart = false
        microphoneDenied = false
        ended = nil
        shown = nil
        controller.dismissEnded()
        controller.start()
    }

    // MARK: Events

    public func setTitle(_ text: String) { controller.setTitle(text) }

    public func pauseOrResume() {
        guard let active = controller.state.activeRecording else { return }
        if active.pause == nil { controller.pause() } else { controller.resume() }
    }

    public func finish() {
        guard let active = controller.state.activeRecording else { return }
        controller.finish(title: active.title)
    }

    /// Library, or the header's chevron: back to the Library while the recording continues.
    public func minimise() { close() }

    public func perform(_ action: RecordingBanner.Action) {
        switch action {
        case .resume: controller.resume()
        case .openSettings: onEffect?(.openSettings)
        case .tryAgain: startCapture()
        case .openNote:
            if let noteID = ended?.noteID { leave(.openNote(noteID, modelDownload: false)) } else { close() }
        }
    }

    // MARK: The recorder

    private func follow(_ state: RecordingState) {
        switch state {
        case .starting, .finishing:
            sawCapture = true
        case .active(let active):
            sawCapture = true
            shown = active
            // The field starts with the default title, unless one was typed while starting; the user may clear it.
            if prefilled != active.noteID {
                prefilled = active.noteID
                if active.title.isEmpty { controller.setTitle(active.defaultTitle) }
            }
        case .ended(let noteID, let outcome):
            guard sawCapture else { return }
            sawCapture = false
            ended(noteID, outcome)
        case .idle:
            break
        }
    }

    /// Runs in the turn the end is told, so the banner, the phase and `.show` never disagree.
    private func ended(_ noteID: UUID?, _ outcome: RecordingOutcome) {
        guard case .saved(let next) = outcome else {
            ended = Ended(outcome: outcome, noteID: noteID)
            controller.dismissEnded()
            if outcome != .couldNotStart {
                appeared()
                onEffect?(.show)
            }
            return
        }
        controller.dismissEnded()
        guard let noteID else { return close() }
        guard next == .askConsent else { return leave(.openNote(noteID, modelDownload: false)) }
        let asked = generation
        Task {
            let download = await ports.modelsMissing()
            // A new showing or recording since the finish owns the screen now.
            guard asked == generation, !controller.state.inProgress else { return }
            leave(.openNote(noteID, modelDownload: download))
        }
    }

    private func leave(_ effect: RecordingEffect) {
        dropPendingStart()
        guard !leaving else { return }
        leaving = true
        onEffect?(effect)
    }

    private func close() { leave(.close) }

    /// A start waiting for microphone access belongs to the screen; once it leads away, coming back from Settings
    /// must not start a recording off screen.
    private func dropPendingStart() {
        pendingStart = false
        microphoneDenied = false
    }
}
