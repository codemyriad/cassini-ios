import Foundation
import Observation
import Synchronization
import os
import CassiniEngine
import CassiniNotebook
import CassiniWhistle

/// D78's live model choice and two suggestion placements. Hashing stays off the UI and cooperative executors.
@MainActor @Observable final class SpeechModelsStore {
    private struct Selection: Sendable {
        var installation: ParakeetInstallation = .missing
        var preference: SpeechModelPreference = .automatic
    }
    private enum Key {
        static let preference = "speech.modelPreference"
        static let suggestion = "speech.parakeetSuggestion"
        static let announced = "speech.parakeetDefaultAnnounced"
    }
    nonisolated private let selection = Mutex(Selection())
    nonisolated private let whistle: Mutex<WhistleCapability>
    nonisolated let parakeetCapable: Bool
    nonisolated private let platform: PlatformFacts
    nonisolated private let physicalMemory: UInt64
    nonisolated private let availableMemory: @Sendable () -> Int64?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let storage: any StorageProbe
    nonisolated private let installed: @Sendable () -> Bool
    nonisolated private let verified: @Sendable () -> Bool
    @ObservationIgnored private let verify: @Sendable () throws -> Bool
    @ObservationIgnored private let verifyBundle: @Sendable () async -> Bool
    @ObservationIgnored private var verificationTask: Task<Void, Never>?
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    @ObservationIgnored var onDownload: @MainActor () -> Void = {}
    private(set) var installation: ParakeetInstallation = .missing
    private(set) var suggestion: ParakeetSuggestionState
    private(set) var promotionVisible = false
    private var afterWhistleVisible = false
    private(set) var preference: SpeechModelPreference

    init(root: URL, defaults: UserDefaults, storage: any StorageProbe, whistle: WhistleCapability,
         parakeetLinked: Bool, platform: PlatformFacts, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
         availableMemory: @escaping @Sendable () -> Int64? = { let n = os_proc_available_memory(); return n > 0 ? Int64(n) : nil },
         installed: (@Sendable () -> Bool)? = nil, verified: (@Sendable () -> Bool)? = nil,
         verify: (@Sendable () throws -> Bool)? = nil,
         verifyBundle: @escaping @Sendable () async -> Bool = { await WhistleRuntime.verifyBundle() }) {
        self.verifyBundle = verifyBundle
        self.root = root; self.defaults = defaults; self.storage = storage; self.whistle = Mutex(whistle)
        self.physicalMemory = physicalMemory; self.availableMemory = availableMemory; self.platform = platform
        parakeetCapable = parakeetLinked && SpeechCapability.parakeetCapable(physicalMemory: physicalMemory)
        self.installed = installed ?? { ModelCatalog.parakeet.ready(in: root) }
        self.verified = verified ?? { ModelVerifier.shared.isChecked(ModelCatalog.parakeet, in: root) }
        self.verify = verify ?? { try ModelVerifier.shared.verify(ModelCatalog.parakeet, in: root) }
        preference = defaults.string(forKey: Key.preference).flatMap(SpeechModelPreference.init(rawValue:)) ?? .automatic
        if defaults.string(forKey: Key.preference) == nil && defaults.bool(forKey: InternalWhistle.preference) {
            preference = .whistle // Preserve the earlier beta's explicit opt-in, not its off-by-default state.
        }
        suggestion = defaults.data(forKey: Key.suggestion).flatMap { try? JSONDecoder().decode(ParakeetSuggestionState.self, from: $0) } ?? .init()
        let initial = preference
        selection.withLock { $0.preference = initial }
    }

    nonisolated var whistleCapability: WhistleCapability { whistle.withLock { $0 } }
    func verifyBundledSpeech() async {
        let verified = await verifyBundle()
        whistle.withLock { $0.bundleVerified = verified }
        let recognizer = selectedRecognizer().rawValue
        Logger(subsystem: "io.codemyriad.cassini", category: "WhistleBundle")
            .notice("Speech selection after bundle verification; verified=\(verified, privacy: .public) physicalMemory=\(self.physicalMemory, privacy: .public) recognizer=\(recognizer, privacy: .public)")
        onChange()
    }

    var policy: SpeechModelPolicy {
        SpeechModelPolicy(whistleAvailable: whistle.withLock { $0.available }, parakeetLinked: parakeetCapable,
            physicalMemory: physicalMemory, availableMemory: availableMemory(), parakeetInstallation: effectiveInstallation(installation),
            availableDiskBytes: storage.availableBytes(at: root), downloadPlan: ModelPlan.of(root: root))
    }

    nonisolated func selectedRecognizer() -> SpeechRecognizer {
        var current = selection.withLock { $0 }
        current.installation = effectiveInstallation(current.installation)
        let facts = SpeechModelPolicy(whistleAvailable: whistle.withLock { $0.available }, parakeetLinked: parakeetCapable,
            physicalMemory: physicalMemory, availableMemory: availableMemory(), parakeetInstallation: current.installation,
            availableDiskBytes: 0, downloadPlan: ModelPlan([]))
        // Apple remains a candidate whose adapter checks live hardware/locale eligibility before queue admission. Where
        // nothing can run, the Apple identity reaches the unavailable candidate, which refuses the job.
        return facts.recognizer(preference: current.preference, platform: platform) ?? .appleSpeech
    }

    nonisolated private func effectiveInstallation(_ published: ParakeetInstallation) -> ParakeetInstallation {
        if installed() && verified() { return .verified }
        return published == .verified ? .missing : published
    }

    func choose(_ recognizer: SpeechRecognizer) {
        guard recognizer == .whistle && whistle.withLock({ $0.available }) || recognizer == .parakeet && policy.parakeetInstallation == .verified && policy.parakeetRunnable else { return }
        preference = recognizer == .whistle ? .whistle : .parakeet
        defaults.set(preference.rawValue, forKey: Key.preference)
        let value = preference
        selection.withLock { $0.preference = value }
        updatePromotion()
    }

    func shows(_ placement: ParakeetSuggestionPlacement) -> Bool {
        if placement == .afterWhistle && afterWhistleVisible {
            return !suggestion.dismissed && policy.canSuggestParakeet
        }
        return suggestion.shows(placement, policy: policy)
    }
    func markAfterWhistleShown() {
        afterWhistleVisible = true
        suggestion.markAfterWhistlePresented()
        saveSuggestion()
    }
    func hideAfterWhistle() { afterWhistleVisible = false }
    func dismissSuggestion() {
        suggestion.dismiss()
        saveSuggestion()
    }
    func requestDownload() { if policy.canSuggestParakeet { onDownload() } }
    func markPromotionShown() { defaults.set(true, forKey: Key.announced) }
    func dismissPromotion() { promotionVisible = false; markPromotionShown() }

    func completed(_ job: Job, outcome: JobOutcome) {
        guard let recognizer = job.recognizer.flatMap(SpeechRecognizer.init(rawValue:)) else { return }
        let succeeded: Bool
        if case .done = outcome { succeeded = true } else { succeeded = false }
        suggestion.completed(recognizer: recognizer, kind: job.kind, succeeded: succeeded)
        saveSuggestion()
    }

    func diagnostics(base: TranscriptionJob.Diagnostics?) -> TranscriptionJob.Diagnostics {
        .init(started: { base?.started($0) }, finished: { [weak self] job, outcome in
            base?.finished(job, outcome)
            Task { @MainActor [weak self] in self?.completed(job, outcome: outcome) }
        })
    }

    func installerChanged(_ status: PinnedModelInstaller.Status) {
        switch status {
        case .installing(let parts, _, _) where parts.contains(.speech):
            if installation != .verified { publish(.installing) }
        case .idle: refresh()
        default: break
        }
    }

    /// Resolve installed-model verification before releasing cold-start queue/recording/import admission.
    /// The verifier still runs on its utility worker; awaiting this task does not block the main actor.
    func verifyInstalledSpeech() async {
        refresh()
        if preference == .whistle && whistleCapability.available { return }
        await verificationTask?.value
    }

    /// A size-matching directory is only a candidate. An explicit Whistle choice remains usable while this check
    /// runs; automatic/Parakeet cold-start admission awaits it through verifyInstalledSpeech().
    func refresh() {
        guard verificationTask == nil else { return }
        guard parakeetCapable, installed() else { publish(.missing); return }
        if verified() { publish(.verified); return }
        publish(.checking)
        let verify = verify
        verificationTask = Task { [weak self] in
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: Result<Bool, any Error>.success(try verify())) }
                    catch { continuation.resume(returning: .failure(error)) }
                }
            }
            guard let self else { return }
            self.verificationTask = nil
            switch result {
            case .success: self.publish(self.installed() && self.verified() ? .verified : .missing)
            case .failure: self.publish(self.installed() && self.verified() ? .verified : .unavailable)
            }
        }
    }

    private func publish(_ value: ParakeetInstallation) {
        installation = value
        selection.withLock { $0.installation = value }
        updatePromotion()
        onChange()
    }
    private func updatePromotion() {
        if installation == .verified && preference != .whistle && !defaults.bool(forKey: Key.announced) {
            promotionVisible = true
        } else if installation != .verified || preference == .whistle { promotionVisible = false }
    }
    private func saveSuggestion() { defaults.set(try? JSONEncoder().encode(suggestion), forKey: Key.suggestion) }
}
