import Foundation
import Observation
import CassiniNotebook

/// The models a job still needs, the download each one shows and the free space their install asks for, as the Model
/// download screen shows them. On a Parakeet device (decision D2) the figures are the catalog's (`ModelPlan`): speech
/// shows Ultra's download alone, as D16's model rows do (its speech detector, under 1 MB, has no row of its own but is
/// installed with it and counts in the free space); the speakers row shows the download of each speaker model still
/// missing; the free space is the whole install's. On a device that keeps Apple Speech the speech part is Apple's
/// assets, whose size iOS does not tell: it shows none, and the free space uses an estimate (`speechInstallBytes`).
public struct ModelDownloadPlan: Hashable, Sendable {
    /// Missing parts, in `ModelPart` order.
    public var missing: [ModelPart]
    /// Free space to have before the first byte; 0 when nothing is missing.
    public var requiredFreeBytes: Int64
    /// The plan of a note's speakers-only job (Identify speakers): it installs the speaker models and transcribes
    /// nothing.
    public var speakersOnly: Bool
    /// The download shown next to each missing part; Apple's speech assets have none.
    public var downloadBytes: [ModelPart: Int64]

    public init(missing: [ModelPart], requiredFreeBytes: Int64, speakersOnly: Bool = false,
                downloadBytes: [ModelPart: Int64] = [:]) {
        self.missing = ModelPart.allCases.filter(missing.contains)
        self.requiredFreeBytes = requiredFreeBytes
        self.speakersOnly = speakersOnly
        self.downloadBytes = downloadBytes.filter { missing.contains($0.key) }
    }

    /// The plan for `missing`, asking for `speechInstallBytes` for the speech model and `speakersInstallBytes` (what
    /// the speaker models' installer checks, `SpeakerAnalyzing.modelInstallBytes`) for the speaker models, which serve
    /// telling speakers apart and recognising saved voices.
    public init(missing: [ModelPart], speakersInstallBytes: Int64, speakersOnly: Bool = false) {
        let speakers = missing.contains(.speakers) || missing.contains(.voices)
        self.init(missing: missing, requiredFreeBytes: (missing.contains(.speech) ? Self.speechInstallBytes : 0)
                  + (speakers ? speakersInstallBytes : 0), speakersOnly: speakersOnly)
    }

    /// What the model download screen installs. The speech model counts unless it is ready or cannot be used for the
    /// language. The speaker models count when they are not ready and either a note's job tells speakers apart
    /// (`identifySpeakers`) or there is no note: the standalone download from a Settings row installs every part that
    /// is not ready, whatever the Speakers switch says. A note's speakers-only job (Identify speakers) needs the speaker
    /// models alone.
    ///
    /// `catalog` is what the catalog still has to install (`ModelPlan.of(root:)`): it gives each part's download, and
    /// on a Parakeet device (`recognizer`) the free space too. Without it a part shows no size.
    public static func plan(speech: ModelPartStatus, speakers: ModelPartStatus, forNote: Bool, identifySpeakers: Bool,
                            speakersOnly: Bool = false, speakersInstallBytes: Int64,
                            recognizer: SpeechRecognizer = .appleSpeech, catalog: ModelPlan? = nil) -> ModelDownloadPlan {
        var missing: [ModelPart] = []
        if speech != .ready, speech != .unsupported, !speakersOnly { missing.append(.speech) }
        if speakers != .ready, !forNote || identifySpeakers || speakersOnly { missing.append(.speakers) }
        var plan = ModelDownloadPlan(missing: missing, speakersInstallBytes: speakersInstallBytes, speakersOnly: speakersOnly)
        guard let catalog else { return plan }
        let parakeet = recognizer == .parakeet
        // The catalog's items of each missing part; the speakers row stands for both speaker models.
        func items(_ part: ModelPart) -> [ModelPlan.Item] {
            catalog.missing.filter { part == .speakers ? SpeakerModels.parts.contains($0.part) : $0.part == part }
        }
        for part in plan.missing where part != .speech || parakeet {
            if part == .speech {
                // The speech part is missing exactly while Ultra is.
                plan.downloadBytes[part] = fullDownloadBytes(.speech)
                continue
            }
            let found = items(part)
            let models = found.isEmpty ? Self.models(of: part) : found.flatMap(\.models)
            plan.downloadBytes[part] = models.reduce(0) { $0 + $1.downloadBytes }
        }
        if parakeet, plan.missing.contains(.speech) {
            let all = plan.missing.flatMap(items)
            if !all.isEmpty { plan.requiredFreeBytes = ModelPlan(all).requiredFreeBytes }
        }
        return plan
    }

    /// Every model of what a row stands for: the speakers row is the diarizer and CAM++.
    private static func models(of part: ModelPart) -> [ModelDescriptor] {
        part == .speakers ? ModelPart.speakers.models + ModelPart.voices.models : part.models
    }

    /// The download a part shows when nothing of it is installed: Ultra's for speech ("443 MB", D16; the speech
    /// detector has no row of its own), the diarizer and CAM++ for the speakers row (Settings shows the voices row as
    /// coming with it).
    public static func fullDownloadBytes(_ part: ModelPart) -> Int64 {
        if part == .speech { return part.primary.downloadBytes }
        return models(of: part == .voices ? .speakers : part).reduce(0) { $0 + $1.downloadBytes }
    }

    public var isEmpty: Bool { missing.isEmpty }

    /// The one-time download the body quotes ("about 531 MB"): the sum of the parts' downloads, nil when a part shows
    /// none.
    public var totalDownloadBytes: Int64? {
        guard !missing.isEmpty, missing.allSatisfy({ downloadBytes[$0] != nil }) else { return nil }
        return missing.reduce(0) { $0 + (downloadBytes[$1] ?? 0) }
    }

    /// iOS does not tell the speech assets' size before they are downloaded, so the space check uses an estimate for
    /// one language that covers the download and the installed copy.
    public static let speechInstallBytes: Int64 = 512 * 1024 * 1024
}

/// What the model download screen reads and changes. The app binds it to its stores; tests pass a fake.
@MainActor public protocol ModelDownloadPorts: AnyObject {
    /// The missing parts and the free space their install needs. With a note, the parts its job uses; without one
    /// (the standalone download from Settings), every part that is not ready.
    func plan(for noteID: UUID?) async -> ModelDownloadPlan
    /// The language the recognizer is set to hear (`SettingsStore.speechLanguage`, BCP 47) on a device that keeps
    /// Apple Speech; nil where the recognizer hears the language itself (Parakeet).
    func speechLanguage() -> String?
    /// Free bytes where the models go.
    func usableBytes() async -> Int64
    /// Agrees to downloading `parts`.
    func recordConsent(for parts: [ModelPart])
    /// "Not now — keep the audio" for a plan with the speech model: no automatic transcription asks again.
    func recordDeclined()
    /// Puts the note in the queue again with its job's kind.
    @discardableResult func transcribe(_ noteID: UUID) async -> TranscribeOutcome
    /// Downloads `parts` on their own, without a note.
    func downloadModels(_ parts: [ModelPart])
    /// Asks for notifications once (`NoticeCenter.askNotificationsOnce`) and waits for the answer; a denial blocks
    /// nothing.
    func askNotificationsOnce() async
}

/// The model download screen ("Transcribe on this device"). With a note it offers "Download and transcribe" (for a
/// speakers-only job "Download and identify speakers"), without one a standalone "Download".
///
/// - The plan is read when the screen opens. When nothing is missing (a stale entry) the screen closes itself, putting
///   its note in the queue first.
/// - Download checks the free space first; when it is short the screen shows "Not enough storage" with Retry and
///   records no consent. Then notifications are asked for once, the consent is recorded, the note is queued (or the
///   standalone download starts), and the screen closes.
/// - "Not now — keep the audio" records the refusal of the speech model when the plan has it, and closes; declining
///   the speaker models alone refuses nothing for later transcriptions. Close only closes.
@MainActor @Observable
public final class ModelDownloadModel {
    public enum Effect: Hashable, Sendable {
        case close
        /// "Where the models come from · Privacy".
        case openLicenses
    }

    public let noteID: UUID?
    /// Nil until it is read, and when nothing is missing (the screen is never shown without parts).
    public private(set) var plan: ModelDownloadPlan?
    /// The primary button shows its spinner.
    public private(set) var busy = false
    /// The bytes the "Not enough storage" banner asks for; nil without that banner.
    public private(set) var noSpaceBytes: Int64?
    /// The speech language the line under the parts names (D59 (2): "Cassini recognises speech in …, change it in
    /// Settings › Speech language"): read with the plan, on a device that keeps Apple Speech, for a plan that
    /// transcribes. Nil on a Parakeet device, which hears the language, and for a speakers-only job, which recognises
    /// no speech.
    public private(set) var speechLanguage: String?

    @ObservationIgnored private let ports: any ModelDownloadPorts
    @ObservationIgnored public var onEffect: (Effect) -> Void = { _ in }
    @ObservationIgnored private var closing = false

    public init(noteID: UUID?, ports: any ModelDownloadPorts) {
        self.noteID = noteID
        self.ports = ports
    }

    /// "Download and transcribe" with a note, else "Download".
    public var withNote: Bool { noteID != nil }

    /// "Download and identify speakers": the note's job is speakers-only.
    public var identifiesSpeakers: Bool { withNote && plan?.speakersOnly == true }

    /// Reads the plan once the screen is shown.
    public func load() async {
        let plan = await ports.plan(for: noteID)
        if plan.isEmpty { await closeStale(); return }
        speechLanguage = plan.speakersOnly ? nil : ports.speechLanguage()
        self.plan = plan
    }

    /// Download, and Retry in the no-space banner.
    public func download() async {
        guard !busy, !closing else { return }
        busy = true
        let plan = await ports.plan(for: noteID)
        if plan.isEmpty { await closeStale(); return }
        self.plan = plan
        guard await ports.usableBytes() >= plan.requiredFreeBytes else {
            noSpaceBytes = plan.requiredFreeBytes
            busy = false
            return
        }
        noSpaceBytes = nil
        await ports.askNotificationsOnce()
        ports.recordConsent(for: plan.missing)
        if let noteID { await ports.transcribe(noteID) } else { ports.downloadModels(plan.missing) }
        close()
    }

    public func notNow() {
        guard !closing else { return }
        if plan?.missing.contains(.speech) == true { ports.recordDeclined() }
        close()
    }

    public func openSources() { onEffect(.openLicenses) }

    public func close() {
        guard !closing else { return }
        closing = true
        onEffect(.close)
    }

    /// Nothing is missing: the note (when there is one) goes in the queue, and the screen goes.
    private func closeStale() async {
        plan = nil
        if let noteID { await ports.transcribe(noteID) }
        close()
    }
}
