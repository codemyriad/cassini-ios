import Foundation
import CassiniEngine
import CassiniNotebook

/// `ModelDownloadPorts` over the app's stores and models.
@MainActor final class ModelDownloadAdapter: ModelDownloadPorts {
    private let settings: SettingsStore
    private let processing: ProcessingStore
    private let transcriber: any Transcribing
    private let analyzer: any SpeakerAnalyzing
    private let storage: any StorageProbe
    private let notifier: any Notifier
    private let root: URL

    init(settings: SettingsStore, processing: ProcessingStore, transcriber: any Transcribing,
         analyzer: any SpeakerAnalyzing, storage: any StorageProbe, notifier: any Notifier, root: URL) {
        self.settings = settings; self.processing = processing; self.transcriber = transcriber
        self.analyzer = analyzer; self.storage = storage; self.notifier = notifier; self.root = root
    }

    /// Apple's speech model for the chosen language, unless it is installed or cannot be used here; the speaker
    /// models when speakers are told apart.
    func plan() async -> ModelPlan {
        var missing: [ModelPart] = []
        switch await transcriber.assetStatus(locale: Locale(identifier: settings.speechLanguage)) {
        case .ready, .unsupported: break
        default: missing.append(.speech)
        }
        if settings.identifySpeakers, await analyzer.modelStatus() != .ready { missing.append(.speakers) }
        return ModelPlan(missing: missing)
    }

    func usableBytes() async -> Int64 { storage.availableBytes(at: root) }

    func recordConsent(for parts: [ModelPart]) {
        if parts.contains(.speech) { settings.recordConsent() }
        if parts.contains(.speakers) { settings.speakerDownloadsAllowed = true }
    }

    func recordDeclined() { settings.recordDeclined() }

    func transcribe(_ noteID: UUID) async -> TranscribeOutcome {
        await processing.transcribe(noteID, kind: processing.state.jobs[noteID]?.kind ?? .transcribe)
    }

    /// The speech model is installed now, with its progress and failure in `ProcessingStore.speechInstall`; the
    /// speaker models download with the first speaker analysis.
    func downloadModels(_ parts: [ModelPart]) {
        guard parts.contains(.speech) else { return }
        processing.installSpeechModel(language: settings.speechLanguage)
    }

    func shouldAskNotifications() async -> Bool {
        guard !settings.notificationsAsked else { return false }
        return await notifier.authorizationStatus() == .notDetermined
    }

    func askNotifications() async {
        settings.markNotificationsAsked()
        await notifier.requestOnce()
    }
}

