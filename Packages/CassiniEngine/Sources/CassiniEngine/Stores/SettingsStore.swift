import Foundation
import Observation
import CassiniNotebook

/// The app's preferences, read once from `UserDefaults` and written back on every change. Keys are `SettingsKeys`;
/// timestamps are stored as epoch milliseconds.
@MainActor @Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any AppClock

    /// BCP-47.
    public var speechLanguage: String { didSet { defaults.set(speechLanguage, forKey: SettingsKeys.speechLanguage) } }
    public var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: SettingsKeys.autoTranscribe) } }
    public var identifySpeakers: Bool { didSet { defaults.set(identifySpeakers, forKey: SettingsKeys.identifySpeakers) } }
    public var automaticallyNameVoices: Bool {
        didSet { defaults.set(automaticallyNameVoices, forKey: SettingsKeys.automaticallyNameVoices) }
    }
    public var speakerModelIdentity: String? {
        didSet { write(speakerModelIdentity, SettingsKeys.speakerModelIdentity) }
    }
    public var modelsConsentAt: Date? { didSet { write(modelsConsentAt, SettingsKeys.modelsConsentAt) } }
    public var modelsDeclinedAt: Date? { didSet { write(modelsDeclinedAt, SettingsKeys.modelsDeclinedAt) } }
    public var speakerModelsConsentAt: Date? { didSet { write(speakerModelsConsentAt, SettingsKeys.speakerModelsConsentAt) } }
    public var queueHold: QueueHold? { didSet { write(queueHold?.rawValue, SettingsKeys.queueHold) } }
    public private(set) var recoveredAck: Date? { didSet { write(recoveredAck, SettingsKeys.recoveredAck) } }
    public private(set) var importFailureAck: Date? { didSet { write(importFailureAck, SettingsKeys.importFailureAck) } }
    public private(set) var downloadFailureAck: Date? { didSet { write(downloadFailureAck, SettingsKeys.downloadFailureAck) } }
    public private(set) var notificationsAsked: Bool {
        didSet { defaults.set(notificationsAsked, forKey: SettingsKeys.notificationsAsked) }
    }
    public private(set) var finalizationMs: Int64? { didSet { write(finalizationMs, SettingsKeys.finalizationMs) } }
    public private(set) var trashLastPurgeAt: Date? { didSet { write(trashLastPurgeAt, SettingsKeys.trashLastPurgeAt) } }
    public private(set) var voicesGeneration: Int { didSet { defaults.set(voicesGeneration, forKey: SettingsKeys.voicesGeneration) } }

    public init(defaults: UserDefaults, clock: any AppClock, defaultLanguage: String = Locale.current.identifier(.bcp47)) {
        self.defaults = defaults
        self.clock = clock
        let storedLanguage = defaults.string(forKey: SettingsKeys.speechLanguage)
        speechLanguage = storedLanguage.map { Locale(identifier: $0).identifier(.bcp47) } ?? defaultLanguage
        autoTranscribe = defaults.object(forKey: SettingsKeys.autoTranscribe) as? Bool ?? true
        identifySpeakers = defaults.object(forKey: SettingsKeys.identifySpeakers) as? Bool ?? true
        automaticallyNameVoices = defaults.bool(forKey: SettingsKeys.automaticallyNameVoices)
        speakerModelIdentity = defaults.string(forKey: SettingsKeys.speakerModelIdentity)
        modelsConsentAt = Self.date(defaults, SettingsKeys.modelsConsentAt)
        modelsDeclinedAt = Self.date(defaults, SettingsKeys.modelsDeclinedAt)
        speakerModelsConsentAt = Self.date(defaults, SettingsKeys.speakerModelsConsentAt)
        queueHold = defaults.string(forKey: SettingsKeys.queueHold).flatMap(QueueHold.init(rawValue:))
        recoveredAck = Self.date(defaults, SettingsKeys.recoveredAck)
        importFailureAck = Self.date(defaults, SettingsKeys.importFailureAck)
        downloadFailureAck = Self.date(defaults, SettingsKeys.downloadFailureAck)
        notificationsAsked = defaults.bool(forKey: SettingsKeys.notificationsAsked)
        finalizationMs = (defaults.object(forKey: SettingsKeys.finalizationMs) as? NSNumber)?.int64Value
        trashLastPurgeAt = Self.date(defaults, SettingsKeys.trashLastPurgeAt)
        voicesGeneration = defaults.integer(forKey: SettingsKeys.voicesGeneration)
        migrateSchemaOne(storedLanguage: storedLanguage)
    }

    /// Whether the speech model may be downloaded.
    public var downloadsAllowed: Bool {
        get { modelsConsentAt != nil }
        set { modelsConsentAt = newValue ? (modelsConsentAt ?? clock.now) : nil }
    }

    /// Whether the speaker models may be downloaded.
    public var speakerDownloadsAllowed: Bool {
        get { speakerModelsConsentAt != nil }
        set { speakerModelsConsentAt = newValue ? (speakerModelsConsentAt ?? clock.now) : nil }
    }

    public func recordConsent() { modelsConsentAt = clock.now }
    public func recordDeclined() { modelsDeclinedAt = clock.now }

    /// Records that recovered recordings up to `date` were seen; the acknowledgement never goes back.
    public func acknowledgeRecovered(upTo date: Date) {
        recoveredAck = max(recoveredAck ?? .distantPast, date)
    }

    public func acknowledgeImportFailure(at date: Date) { importFailureAck = date }
    public func acknowledgeDownloadFailure(at date: Date) { downloadFailureAck = date }
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

    private func migrateSchemaOne(storedLanguage: String?) {
        if let storedLanguage, storedLanguage != speechLanguage {
            defaults.set(speechLanguage, forKey: SettingsKeys.speechLanguage)
        }
        if defaults.object(forKey: SettingsKeys.legacyModelDownloadsAllowed) != nil {
            if defaults.bool(forKey: SettingsKeys.legacyModelDownloadsAllowed), modelsConsentAt == nil { modelsConsentAt = clock.now }
            defaults.removeObject(forKey: SettingsKeys.legacyModelDownloadsAllowed)
        }
        if defaults.object(forKey: SettingsKeys.legacySpeakerDownloadsAllowed) != nil {
            if defaults.bool(forKey: SettingsKeys.legacySpeakerDownloadsAllowed), speakerModelsConsentAt == nil {
                speakerModelsConsentAt = clock.now
            }
            defaults.removeObject(forKey: SettingsKeys.legacySpeakerDownloadsAllowed)
        }
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
