import Foundation
import Observation
import Synchronization
import CassiniNotebook

/// The app's preferences, read once from `UserDefaults` and written back on every change. Keys are `SettingsKeys`;
/// timestamps are stored as epoch milliseconds.
@MainActor @Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored nonisolated private let recognition = Mutex(true)
    @ObservationIgnored nonisolated private let modeLock = Mutex(TranscriptionMode.defaultMode)
    @ObservationIgnored nonisolated private let speakersLock = Mutex(true)

    @ObservationIgnored private weak var draftNames: DraftNamesStore?
    @ObservationIgnored private var recognitionCleanup: Task<Void, Never>?

    /// Bind before restoring jobs. The flag changes immediately; paused drafts are scrubbed on a worker.
    public func bindDraftNames(_ drafts: DraftNamesStore?) {
        draftNames = drafts
        updateDraftRecognition()
    }

    public func settleDraftRecognition() async { await recognitionCleanup?.value }

    private func updateDraftRecognition() {
        guard let drafts = draftNames else { return }
        drafts.setRecognitionAllowed(recogniseSavedVoices)
        guard !recogniseSavedVoices else { return }
        let previous = recognitionCleanup
        recognitionCleanup = Task.detached(priority: .utility) {
            await previous?.value
            drafts.mutateAll { $0.withoutUnconfirmedMatches() }
        }
    }

    /// Inference callbacks see the current switch without hopping to or blocking the main actor.
    public nonisolated var allowsSavedVoiceRecognition: Bool { recognition.withLock { $0 } }
    /// Off-main-actor snapshot of `transcriptionMode` for recording-time precomputation.
    public nonisolated var currentTranscriptionMode: TranscriptionMode { modeLock.withLock { $0 } }
    /// Off-main-actor snapshot of `identifySpeakers` for recording-time precomputation.
    public nonisolated var currentIdentifySpeakers: Bool { speakersLock.withLock { $0 } }

    public private(set) var cloudBackup: Bool
    public private(set) var includeSavedVoicesInBackups: Bool
    public private(set) var backupNoticeDismissed: Bool
    public private(set) var voiceSetupAnswered: Bool
    public private(set) var rememberPeopleIName: Bool

    public func dismissBackupNotice() {
        backupNoticeDismissed = true
        defaults.set(true, forKey: "backup.noticeDismissed")
    }

    /// Answer and default are one cached defaults record. Dismissing keeps the current default.
    /// UserDefaults schedules persistence; no synchronous disk flush runs on the main actor.
    public func answerVoiceSetup(enable: Bool?) {
        let remember = enable ?? rememberPeopleIName
        defaults.set(["answered": true, "remember": remember], forKey: "voices.rememberPreference")
        rememberPeopleIName = remember
        voiceSetupAnswered = true
    }

    public func setRememberPeopleIName(_ remember: Bool) { answerVoiceSetup(enable: remember) }

    func commitBackup(cloud: Bool, voices: Bool) {
        // One defaults record keeps both switches consistent across launches.
        defaults.set(["cloud": cloud, "voices": voices], forKey: "backup.inclusion")
        cloudBackup = cloud
        includeSavedVoicesInBackups = voices
    }

    /// BCP-47.
    public var speechLanguage: String { didSet { defaults.set(speechLanguage, forKey: SettingsKeys.speechLanguage) } }
    public var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: SettingsKeys.autoTranscribe) } }
    public var identifySpeakers: Bool {
        didSet {
            speakersLock.withLock { $0 = identifySpeakers }
            defaults.set(identifySpeakers, forKey: SettingsKeys.identifySpeakers)
        }
    }
    public var recogniseSavedVoices: Bool {
        didSet {
            recognition.withLock { $0 = recogniseSavedVoices }
            defaults.set(recogniseSavedVoices, forKey: SettingsKeys.recogniseSavedVoices)
            updateDraftRecognition()
        }
    }
    public var automaticallyNameVoices: Bool {
        didSet { defaults.set(automaticallyNameVoices, forKey: SettingsKeys.automaticallyNameVoices) }
    }
    public var modelsConsentAt: Date? { didSet { write(modelsConsentAt, SettingsKeys.modelsConsentAt) } }
    public var modelsDeclinedAt: Date? { didSet { write(modelsDeclinedAt, SettingsKeys.modelsDeclinedAt) } }
    public var speakerModelsConsentAt: Date? { didSet { write(speakerModelsConsentAt, SettingsKeys.speakerModelsConsentAt) } }
    public var queueHold: QueueHold? { didSet { write(queueHold?.rawValue, SettingsKeys.queueHold) } }
    public private(set) var recoveredAck: Date? { didSet { write(recoveredAck, SettingsKeys.recoveredAck) } }
    public private(set) var notificationsAsked: Bool {
        didSet { defaults.set(notificationsAsked, forKey: SettingsKeys.notificationsAsked) }
    }
    public private(set) var finalizationMs: Int64? { didSet { write(finalizationMs, SettingsKeys.finalizationMs) } }
    public private(set) var trashLastPurgeAt: Date? { didSet { write(trashLastPurgeAt, SettingsKeys.trashLastPurgeAt) } }
    public private(set) var voicesGeneration: Int { didSet { defaults.set(voicesGeneration, forKey: SettingsKeys.voicesGeneration) } }
    /// Non-UI `TranscriptionMode` policy seam (`recordOnly`, `afterStop`, `transcribeWhileRecording`); defaults to `.transcribeWhileRecording` (`D111`).
    public var transcriptionMode: TranscriptionMode {
        didSet {
            modeLock.withLock { $0 = transcriptionMode }
            defaults.set(transcriptionMode.rawValue, forKey: SettingsKeys.transcriptionMode)
        }
    }

    public init(defaults: UserDefaults, clock: any AppClock, defaultLanguage: String = Locale.current.identifier(.bcp47)) {
        self.defaults = defaults
        self.clock = clock
        let inclusion = defaults.dictionary(forKey: "backup.inclusion")
        cloudBackup = inclusion?["cloud"] as? Bool ?? true
        includeSavedVoicesInBackups = inclusion?["voices"] as? Bool ?? true
        backupNoticeDismissed = defaults.bool(forKey: "backup.noticeDismissed")
        let voicePreference = defaults.dictionary(forKey: "voices.rememberPreference")
        voiceSetupAnswered = voicePreference?["answered"] as? Bool ?? defaults.bool(forKey: "voices.setupAnswered")
        // Legacy naming always started with Remember on; auto-name is a separate choice.
        rememberPeopleIName = voicePreference?["remember"] as? Bool ?? true
        let storedLanguage = defaults.string(forKey: SettingsKeys.speechLanguage)
        speechLanguage = storedLanguage.map { Locale(identifier: $0).identifier(.bcp47) } ?? defaultLanguage
        autoTranscribe = defaults.object(forKey: SettingsKeys.autoTranscribe) as? Bool ?? true
        identifySpeakers = defaults.object(forKey: SettingsKeys.identifySpeakers) as? Bool ?? true
        recogniseSavedVoices = defaults.object(forKey: SettingsKeys.recogniseSavedVoices) as? Bool ?? true
        automaticallyNameVoices = defaults.bool(forKey: SettingsKeys.automaticallyNameVoices)
        modelsConsentAt = Self.date(defaults, SettingsKeys.modelsConsentAt)
        modelsDeclinedAt = Self.date(defaults, SettingsKeys.modelsDeclinedAt)
        speakerModelsConsentAt = Self.date(defaults, SettingsKeys.speakerModelsConsentAt)
        queueHold = defaults.string(forKey: SettingsKeys.queueHold).flatMap(QueueHold.init(rawValue:))
        recoveredAck = Self.date(defaults, SettingsKeys.recoveredAck)
        notificationsAsked = defaults.bool(forKey: SettingsKeys.notificationsAsked)
        finalizationMs = (defaults.object(forKey: SettingsKeys.finalizationMs) as? NSNumber)?.int64Value
        trashLastPurgeAt = Self.date(defaults, SettingsKeys.trashLastPurgeAt)
        voicesGeneration = defaults.integer(forKey: SettingsKeys.voicesGeneration)
        transcriptionMode = TranscriptionMode.resolve(defaults.object(forKey: SettingsKeys.transcriptionMode)).mode
        recognition.withLock { $0 = recogniseSavedVoices }
        modeLock.withLock { $0 = transcriptionMode }
        speakersLock.withLock { $0 = identifySpeakers }
    }

    /// Whether the speech model may be downloaded.
    public var downloadsAllowed: Bool { modelsConsentAt != nil }

    /// Whether the speaker models may be downloaded.
    public var speakerDownloadsAllowed: Bool { speakerModelsConsentAt != nil }

    /// Consent to download the speech model, given on the model download screen.
    public func recordConsent() { modelsConsentAt = clock.now }
    /// Consent to download the speaker models, given on the model download screen; the first consent is kept.
    public func recordSpeakerConsent() { speakerModelsConsentAt = speakerModelsConsentAt ?? clock.now }
    public func recordDeclined() { modelsDeclinedAt = clock.now }

    /// Records that recovered recordings up to `date` were seen; the acknowledgement never goes back.
    public func acknowledgeRecovered(upTo date: Date) {
        recoveredAck = max(recoveredAck ?? .distantPast, date)
    }

    public func markNotificationsAsked() { notificationsAsked = true }
    public func recordPurge() { trashLastPurgeAt = clock.now }

    /// Folds a measured finalization time into the estimate as `(old * 3 + new) / 4`; the first measure is kept as is.
    @discardableResult public func recordFinalization(_ measuredMs: Int64) -> Int64 {
        let estimate = finalizationMs.map { ($0 * 3 + measuredMs) / 4 } ?? measuredMs
        finalizationMs = estimate
        return estimate
    }

    /// Forget everyone: analyses that started under an older generation keep no voiceprints.
    @discardableResult public func advanceVoicesGeneration() -> Int {
        voicesGeneration += 1
        return voicesGeneration
    }

    private func write(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func write(_ value: Date?, _ key: String) {
        write(value.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }, key)
    }

    private func write(_ value: Int64?, _ key: String) {
        if let value { defaults.set(NSNumber(value: value), forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func date(_ defaults: UserDefaults, _ key: String) -> Date? {
        (defaults.object(forKey: key) as? NSNumber).map { Date(timeIntervalSince1970: Double($0.int64Value) / 1000) }
    }
}

/// The speech consent of `ModelRepository`: `models.consentAt` and `models.declinedAt`.
extension SettingsStore: ModelConsentRecords {
    public func consentAt() async -> Date? { modelsConsentAt }
}
