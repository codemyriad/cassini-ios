import Foundation
import CassiniNotebook

/// D78: automatic selection starts with the bundled model and moves to Parakeet only after verification.
/// This preference selects new jobs; a queued job's stored recognizer remains authoritative.
public enum SpeechModelPreference: String, Codable, CaseIterable, Sendable {
    case automatic, whistle, parakeet
}

public enum ParakeetInstallation: String, Codable, Sendable {
    case missing, checking, installing, verified, unavailable
}

/// Live facts from the existing native runtime, memory probe, verifier and pinned download plan.
/// A directory of the expected size is not a verified model. Verification must finish before promotion.
public struct SpeechModelPolicy: Sendable {
    public var whistleAvailable: Bool
    public var parakeetLinked: Bool
    public var physicalMemory: UInt64
    public var availableMemory: Int64?
    public var parakeetInstallation: ParakeetInstallation
    public var availableDiskBytes: Int64
    public var downloadPlan: ModelPlan

    public init(whistleAvailable: Bool, parakeetLinked: Bool, physicalMemory: UInt64,
                availableMemory: Int64?, parakeetInstallation: ParakeetInstallation,
                availableDiskBytes: Int64, downloadPlan: ModelPlan) {
        self.whistleAvailable = whistleAvailable; self.parakeetLinked = parakeetLinked
        self.physicalMemory = physicalMemory; self.availableMemory = availableMemory
        self.parakeetInstallation = parakeetInstallation; self.availableDiskBytes = availableDiskBytes
        // The speech upgrade must never advertise or require an unrelated speaker-model download.
        self.downloadPlan = ModelPlan(downloadPlan.missing.filter { $0.part == .speech })
    }

    public var parakeetCapable: Bool {
        parakeetLinked && SpeechCapability.parakeetCapable(physicalMemory: physicalMemory)
    }

    public var parakeetRunnable: Bool {
        parakeetCapable && ParakeetMemory.allows(availableBytes: availableMemory, loaded: false)
    }

    /// An unavailable explicit preference falls back to an available model without starting a download.
    /// Nil lets the caller consider a separately checked Apple candidate or show the unavailable state.
    public func selected(preference: SpeechModelPreference = .automatic) -> SpeechRecognizer? {
        if preference == .whistle, whistleAvailable { return .whistle }
        if parakeetInstallation == .verified, parakeetRunnable { return .parakeet }
        return whistleAvailable ? .whistle : nil
    }

    public var canSuggestParakeet: Bool {
        parakeetRunnable && parakeetInstallation == .missing && !downloadPlan.isEmpty
            && downloadPlan.totalBytes > 0 && availableDiskBytes >= downloadPlan.requiredFreeBytes
    }
}

public enum ParakeetSuggestionPlacement: Sendable {
    case settings, afterWhistle
}

/// Persisted booleans only: a dismissal applies to both placements and survives later transcriptions/restarts.
public struct ParakeetSuggestionState: Codable, Equatable, Sendable {
    public private(set) var completedWhistle: Bool
    public private(set) var dismissed: Bool
    public private(set) var afterWhistlePresented: Bool

    public init(completedWhistle: Bool = false, dismissed: Bool = false, afterWhistlePresented: Bool = false) {
        self.completedWhistle = completedWhistle; self.dismissed = dismissed; self.afterWhistlePresented = afterWhistlePresented
    }

    public mutating func completed(recognizer: SpeechRecognizer, kind: JobKind, succeeded: Bool) {
        if recognizer == .whistle, kind != .speakersOnly, succeeded { completedWhistle = true }
    }

    private enum CodingKeys: String, CodingKey { case completedWhistle, dismissed, afterWhistlePresented }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        completedWhistle = try values.decodeIfPresent(Bool.self, forKey: .completedWhistle) ?? false
        dismissed = try values.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        afterWhistlePresented = try values.decodeIfPresent(Bool.self, forKey: .afterWhistlePresented) ?? false
    }
    public mutating func dismiss() { dismissed = true }
    public mutating func markAfterWhistlePresented() { afterWhistlePresented = true }

    public func shows(_ placement: ParakeetSuggestionPlacement, policy: SpeechModelPolicy) -> Bool {
        !dismissed && policy.canSuggestParakeet && (placement == .settings || (completedWhistle && !afterWhistlePresented))
    }
}
