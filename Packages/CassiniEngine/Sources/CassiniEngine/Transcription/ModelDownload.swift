import Foundation
import Observation
import CassiniNotebook

/// The models a job still needs, and the free space their install asks for.
public struct ModelPlan: Hashable, Sendable {
    /// Missing parts, in `ModelPart` order.
    public var missing: [ModelPart]
    /// Free space to have before the first byte; 0 when nothing is missing.
    public var requiredFreeBytes: Int64

    public init(missing: [ModelPart], requiredFreeBytes: Int64? = nil) {
        let ordered = ModelPart.allCases.filter(missing.contains)
        self.missing = ordered
        self.requiredFreeBytes = requiredFreeBytes ?? ordered.reduce(0) { $0 + Self.installBytes($1) }
    }

    public var isEmpty: Bool { missing.isEmpty }

    /// iOS does not tell an asset's size before it is downloaded, so the space check uses an estimate per part that
    /// covers the download and the installed copy: Apple's speech assets for one language, and FluidAudio's speaker
    /// models (one install serves telling speakers apart and recognising saved voices).
    public static func installBytes(_ part: ModelPart) -> Int64 {
        switch part {
        case .speech: 512 * 1024 * 1024
        case .speakers: 128 * 1024 * 1024
        case .voices: 0
        }
    }
}

/// What the model download screen reads and changes. The app binds it to its stores; tests pass a fake.
@MainActor public protocol ModelDownloadPorts: AnyObject {
    /// The missing parts and the free space their install needs.
    func plan() async -> ModelPlan
    /// Free bytes where the models go.
    func usableBytes() async -> Int64
    /// Agrees to downloading `parts`.
    func recordConsent(for parts: [ModelPart])
    /// "Not now — keep the audio".
    func recordDeclined()
    /// Puts the note in the queue again with its job's kind.
    @discardableResult func transcribe(_ noteID: UUID) async -> TranscribeOutcome
    /// Downloads `parts` on their own, without a note.
    func downloadModels(_ parts: [ModelPart])
    /// Notifications should be asked for now: never asked before, and not decided yet.
    func shouldAskNotifications() async -> Bool
    /// Asks for notifications once and waits for the answer; a denial blocks nothing.
    func askNotifications() async
}

/// The model download screen ("Transcribe on this device"). With a note it offers "Download and transcribe", without
/// one a standalone "Download".
///
/// - The plan is read when the screen opens. When nothing is missing (a stale entry) the screen closes itself, putting
///   its note in the queue first.
/// - Download checks the free space first; when it is short the screen shows "Not enough storage" with Retry and
///   records no consent. Then notifications are asked for once, the consent is recorded, the note is queued (or the
///   standalone download starts), and the screen closes.
/// - "Not now — keep the audio" records the refusal and closes. Close only closes.
@MainActor @Observable
public final class ModelDownloadModel {
    public enum Effect: Hashable, Sendable {
        case close
        /// "Where the models come from · Privacy".
        case openLicenses
    }

    public let noteID: UUID?
    /// Nil until it is read, and when nothing is missing (the screen is never shown without parts).
    public private(set) var plan: ModelPlan?
    /// The primary button shows its spinner.
    public private(set) var busy = false
    /// The bytes the "Not enough storage" banner asks for; nil without that banner.
    public private(set) var noSpaceBytes: Int64?

    @ObservationIgnored private let ports: any ModelDownloadPorts
    @ObservationIgnored public var onEffect: (Effect) -> Void = { _ in }
    @ObservationIgnored private var closing = false

    public init(noteID: UUID?, ports: any ModelDownloadPorts) {
        self.noteID = noteID
        self.ports = ports
    }

    /// "Download and transcribe" with a note, else "Download".
    public var withNote: Bool { noteID != nil }

    /// Reads the plan once the screen is shown.
    public func load() async {
        let plan = await ports.plan()
        if plan.isEmpty { await closeStale() } else { self.plan = plan }
    }

    /// Download, and Retry in the no-space banner.
    public func download() async {
        guard !busy, !closing else { return }
        busy = true
        let plan = await ports.plan()
        if plan.isEmpty { await closeStale(); return }
        self.plan = plan
        guard await ports.usableBytes() >= plan.requiredFreeBytes else {
            noSpaceBytes = plan.requiredFreeBytes
            busy = false
            return
        }
        noSpaceBytes = nil
        if await ports.shouldAskNotifications() { await ports.askNotifications() }
        ports.recordConsent(for: plan.missing)
        if let noteID { await ports.transcribe(noteID) } else { ports.downloadModels(plan.missing) }
        close()
    }

    public func notNow() {
        guard !closing else { return }
        ports.recordDeclined()
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
