/// The `UserDefaults` keys of the app's preferences. They are persisted: never rename one.
public enum SettingsKeys {
    public static let speechLanguage = "speechLanguage"
    public static let autoTranscribe = "autoTranscribe"
    public static let identifySpeakers = "identifySpeakers"
    /// Off unless the user turns it on.
    public static let automaticallyNameVoices = "automaticallyNameVoices"
    public static let speakerModelIdentity = "speakerModelIdentity"

    /// Epoch milliseconds of the user's agreement to download the speech model.
    public static let modelsConsentAt = "models.consentAt"
    /// Epoch milliseconds of "Not now — keep the audio".
    public static let modelsDeclinedAt = "models.declinedAt"
    public static let speakerModelsConsentAt = "speakerModels.consentAt"
    /// A `QueueHold` raw value; absent when the queue may run.
    public static let queueHold = "queue.hold"
    /// Epoch milliseconds of the newest recovered recording the user has seen; it never goes back.
    public static let recoveredAck = "notices.recoveredAck"
    public static let importFailureAck = "notices.importFailureAck"
    public static let downloadFailureAck = "notices.downloadFailureAck"
    public static let notificationsAsked = "notifications.asked"
    /// Running estimate of the matching and saving time after the words, in milliseconds.
    public static let finalizationMs = "processing.finalizationMs"
    public static let trashLastPurgeAt = "trash.lastPurgeAt"
    /// Bumped by Forget everyone, so an analysis that started before keeps no voiceprints.
    public static let voicesGeneration = "voices.generation"

    /// Schema 1 booleans, migrated to the consent timestamps on first launch.
    public static let legacyModelDownloadsAllowed = "modelDownloadsAllowed"
    public static let legacySpeakerDownloadsAllowed = "speakerDownloadsAllowed"

    public static let all: [String] = [
        speechLanguage, autoTranscribe, identifySpeakers, automaticallyNameVoices, speakerModelIdentity,
        modelsConsentAt, modelsDeclinedAt, speakerModelsConsentAt, queueHold, recoveredAck, importFailureAck,
        downloadFailureAck, notificationsAsked, finalizationMs, trashLastPurgeAt, voicesGeneration,
    ]
}
