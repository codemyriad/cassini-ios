import Foundation
import Observation
import CassiniNotebook

/// The one recording of the app: the capture, `state`, the waveform `bars` and the policy loop.
///
/// - `start()` creates the live note (`capture.caf`), starts the capture and the Live Activity. A failed start removes
///   the note and its directory and ends as `couldNotStart`.
/// - Start and end are serialised: a Finish during the start waits for it, and a start while a recording is in progress
///   returns false.
/// - Title edits are written 500 ms after the last change; the finish writes the final value, and a blank title
///   becomes the default ("Voice note 8 Oct, 08:14"). A title typed while the capture starts is kept and written once
///   it runs.
/// - A recording has no time limit. The policy loop runs once a second, paused or not, and stops the recording only
///   when the free space falls below the floor (`RecordingPolicy`). That stop, and a failed microphone, save the audio
///   and never queue a transcription.
/// - The finish makes the note plain with its duration and ends with `saved(next)`; then the audio is compressed to
///   M4A, and the note is handed to transcription when `next` is `transcribe`. Such a note is sealed as queued, so a
///   kill during the compression leaves it marked interrupted at the next launch; a refused hand-off makes it audio
///   only, and a note no longer queued when the compression ends (its transcription was cancelled) is not handed off.
///   A seal that cannot be written is shown on screen anyway and written with the note's next write
///   (`RecordingNotes.showUnsaved`), and the note opens audio only; failing that, the next launch's recovery seals it.
/// - Another app taking the audio pauses the recording; it stays paused until the user resumes.
///
/// `RecordingController+Capture.swift` and `+Finish.swift` split this class by topic; each one's header names the
/// internals it touches. The observed state (`state`, `bars`, `finalizing`, `startingTitle`) and the Live Activity
/// are written only in this file: `state` through `setState`, which tells the observers, and the rest through
/// `addLevel`, `setFinalizing` and `publishActivity`/`endActivity`.
@MainActor @Observable
public final class RecordingController {
    public struct Timing: Sendable {
        public var tick: Duration
        public var titleDebounce: Duration
        public init(tick: Duration = .seconds(1), titleDebounce: Duration = .milliseconds(500)) {
            self.tick = tick; self.titleDebounce = titleDebounce
        }
    }

    /// What the controller is built from; the app passes its adapters, tests pass fakes.
    public struct Parts {
        /// Returns once the launch work (recovery, reconcile) is done.
        public var ready: @MainActor () async -> Void
        public var notes: any RecordingNotes
        public var capture: any AudioCapture
        public var storage: any StorageProbe
        public var audio: any AudioProcessing
        public var settings: SettingsStore
        public var handoff: any RecordingHandoff
        /// Whether a saved recording may be transcribed without asking (Android's `RecordingConsent.consented`).
        public var consent: ModelConsent
        public var liveActivity: (any LiveActivityPort)?
        public var notifier: (any Notifier)?
        public var clock: any AppClock
        /// The title of a recording started at the given time ("Voice note 8 Oct, 08:14").
        public var defaultTitle: @Sendable (Date) -> String
        public var timing: Timing

        public init(ready: @escaping @MainActor () async -> Void, notes: any RecordingNotes, capture: any AudioCapture,
                    storage: any StorageProbe, audio: any AudioProcessing, settings: SettingsStore,
                    handoff: any RecordingHandoff, consent: ModelConsent? = nil, liveActivity: (any LiveActivityPort)? = nil,
                    notifier: (any Notifier)? = nil, clock: any AppClock,
                    defaultTitle: @escaping @Sendable (Date) -> String, timing: Timing = Timing()) {
            self.ready = ready; self.notes = notes; self.capture = capture; self.storage = storage; self.audio = audio
            self.settings = settings; self.handoff = handoff
            // Without a model check, only the recorded consent counts.
            self.consent = consent ?? ModelConsent { _, _ in settings.modelsConsentAt != nil }
            self.liveActivity = liveActivity; self.notifier = notifier
            self.clock = clock; self.defaultTitle = defaultTitle; self.timing = timing
        }
    }

    nonisolated public static let captureFilename = "capture.caf"
    nonisolated public static let compressedFilename = "audio.m4a"

    enum Stop { case user, space, microphone }

    public private(set) var state: RecordingState = .idle
    /// The last 7 s of microphone levels.
    public private(set) var bars = WaveformBars()
    /// Notes whose audio is still being compressed after the finish.
    public private(set) var finalizing: Set<UUID> = []
    /// The title typed while the capture starts; the recording takes it once it runs.
    public private(set) var startingTitle: String?

    /// Whether the app is on screen; an automatic stop in the background posts a notification.
    @ObservationIgnored public var isAppActive = true
    /// The compression of a finished recording failed; its original audio stays the recording.
    @ObservationIgnored public var onCompressionFailed: (@MainActor (UUID) -> Void)?

    @ObservationIgnored let parts: Parts
    @ObservationIgnored private var observers: [@MainActor (RecordingState) -> Void] = []
    @ObservationIgnored var operations: Task<Void, Never>?
    @ObservationIgnored var policy: Task<Void, Never>?
    @ObservationIgnored var titleWrite: Task<Void, Never>?
    @ObservationIgnored var compressions: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var events: Task<Void, Never>?
    @ObservationIgnored var captureURL: URL?
    @ObservationIgnored private var activity: RecordingActivityState?
    /// States not yet told to every observer, oldest first.
    @ObservationIgnored private var undelivered: [RecordingState] = []

    public init(parts: Parts) {
        self.parts = parts
        let stream = parts.capture.events
        events = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
    }

    // MARK: Actions

    /// Starts a recording. False when one is already in progress.
    @discardableResult public func start() -> Bool {
        guard !state.inProgress else { return false }
        startingTitle = nil
        setState(.starting)
        serialized { await self.begin() }
        return true
    }

    /// The title field changed: the state keeps the text as typed (up to the title limit), and the note gets it 500 ms
    /// after the last change. While the capture starts the text waits in `startingTitle`.
    public func setTitle(_ text: String) {
        let title = String(text.prefix(NoteTitles.maxLength))
        switch state {
        case .starting:
            startingTitle = title
        case .active(var active):
            guard active.title != title else { return }
            active.title = title
            setState(.active(active))
            scheduleTitleWrite(for: active.noteID)
        case .idle, .finishing, .ended:
            break
        }
    }

    /// The time captured so far, read from the microphone now; 0 without a recording. `ActiveRecording.elapsed` is
    /// refreshed only once a second.
    public var currentElapsed: TimeInterval { state.activeRecording == nil ? 0 : parts.capture.elapsed }

    public func pause() {
        guard var active = state.activeRecording else { return }
        parts.capture.pause()
        active.pause = .user
        active.elapsed = parts.capture.elapsed
        setState(.active(active))
        publishActivity()
    }

    public func resume() {
        guard var active = state.activeRecording, active.pause != nil else { return }
        do { try parts.capture.resume() } catch { return } // Another app still holds the audio: it stays paused.
        active.pause = nil
        setState(.active(active))
        publishActivity()
    }

    /// Stops and saves. `title` is the field's final value; nil keeps the current one (the Live Activity's Finish).
    public func finish(title: String? = nil) {
        serialized { await self.end(.user, title: title) }
    }

    /// The screen has handled `ended`.
    public func dismissEnded() {
        if case .ended = state { setState(.idle) }
    }

    /// Calls `observer` on every change of `state`, on the main actor, right after it.
    public func observe(_ observer: @escaping @MainActor (RecordingState) -> Void) { observers.append(observer) }

    /// Returns once the work asked for so far, the compression after a finish included, is done.
    public func settle() async {
        await operations?.value
        for compression in compressions.values { await compression.value }
    }

    // MARK: Start

    func begin() async {
        var created: UUID?
        do {
            await parts.ready()
            let now = parts.clock.now
            let defaultTitle = parts.defaultTitle(now)
            var note = Note(title: defaultTitle, createdAt: now, audioFilename: Self.captureFilename)
            note.status = .recording; note.audio = .live; note.origin = .recorded
            note.language = parts.settings.speechLanguage
            try await parts.notes.create(note)
            created = note.id
            guard let url = await parts.notes.captureURL(for: note) else { throw CocoaError(.fileNoSuchFile) }
            let format = try await parts.capture.start(url: url)
            captureURL = url
            bars = WaveformBars()
            let typed = startingTitle ?? ""
            startingTitle = nil
            var active = ActiveRecording(noteID: note.id, title: typed, defaultTitle: defaultTitle, format: format,
                                         elapsed: parts.capture.elapsed)
            active.space = policyCheck(elapsed: active.elapsed, at: url).space
            setState(.active(active))
            if !typed.isEmpty { scheduleTitleWrite(for: note.id) }
            let activity = activityState(active)
            self.activity = activity
            parts.liveActivity?.start(noteID: note.id, activity)
            policy = Task { [weak self] in await self?.runPolicy() }
        } catch {
            if let created { try? await parts.notes.discard(created) }
            captureURL = nil
            startingTitle = nil
            setState(.ended(noteID: nil, outcome: .couldNotStart))
        }
    }

    // MARK: Helpers

    /// Changes `state` and tells the observers. Every observer sees every state in order: a change an observer makes
    /// is told once all of them have seen the current one, so the last state each sees is `state`.
    func setState(_ next: RecordingState) {
        guard next != state else { return }
        state = next
        undelivered.append(next)
        guard undelivered.count == 1 else { return } // A delivery is under way; it tells this one too.
        while let current = undelivered.first {
            for observer in observers { observer(current) }
            undelivered.removeFirst()
        }
    }

    /// A microphone level for the waveform, at the time captured so far.
    func addLevel(_ level: Float) {
        bars.add(level, atMs: Int64(parts.capture.elapsed * 1000))
    }

    /// The note's audio is being compressed after the finish, or no longer is.
    func setFinalizing(_ noteID: UUID, _ isFinalizing: Bool) {
        if isFinalizing { finalizing.insert(noteID) } else { finalizing.remove(noteID) }
    }

    /// Ends the Live Activity of the recording.
    func endActivity() {
        parts.liveActivity?.end()
        activity = nil
    }

    /// Runs `work` after every operation asked for before it.
    func serialized(_ work: @escaping @MainActor () async -> Void) {
        let previous = operations
        operations = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func activityState(_ active: ActiveRecording) -> RecordingActivityState {
        RecordingActivityState(title: NoteTitles.clean(active.title) ?? active.defaultTitle,
                               runningSince: active.pause == nil ? parts.clock.now.addingTimeInterval(-active.elapsed) : nil,
                               elapsed: active.elapsed, isPaused: active.pause != nil, warning: active.warning)
    }

    /// Updates the Live Activity when what it shows changed. The running timer counts on its own, so the time is sent
    /// only when the recording pauses or resumes.
    func publishActivity() {
        guard let active = state.activeRecording, var shown = activity else { return }
        let next = activityState(active)
        if next.isPaused != shown.isPaused {
            shown = next
        } else {
            shown.title = next.title
            shown.warning = next.warning
        }
        guard shown != activity else { return }
        activity = shown
        parts.liveActivity?.update(shown)
    }

    static func hasAudio(at url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}
