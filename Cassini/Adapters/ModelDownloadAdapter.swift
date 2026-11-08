import Foundation
import CassiniEngine
import CassiniNotebook

/// `ModelDownloadPorts` over the app's stores and models.
@MainActor final class ModelDownloadAdapter: ModelDownloadPorts {
    private let settings: SettingsStore
    private let processing: ProcessingStore
    private let transcriber: any Transcribing
    private let downloadTranscriber: any Transcribing
    private let speechOnly: Bool
    private let analyzer: any SpeakerAnalyzing
    private let storage: any StorageProbe
    private let notices: NoticeCenter
    private let root: URL
    private let models: URL

    /// `root` is where the notes are, `models` where the pinned models are installed.
    init(settings: SettingsStore, processing: ProcessingStore, transcriber: any Transcribing,
         analyzer: any SpeakerAnalyzing, storage: any StorageProbe, notices: NoticeCenter, root: URL, models: URL,
         downloadTranscriber: (any Transcribing)? = nil, speechOnly: Bool = false) {
        self.settings = settings; self.processing = processing; self.transcriber = transcriber
        self.downloadTranscriber = downloadTranscriber ?? transcriber; self.speechOnly = speechOnly
        self.analyzer = analyzer; self.storage = storage; self.notices = notices; self.root = root; self.models = models
    }

    /// `ModelDownloadPlan.plan` over the speech model of the chosen language and the speaker models' status, for the
    /// note's job, with the sizes of what the catalog still has to install.
    func plan(for noteID: UUID?) async -> ModelDownloadPlan {
        if speechOnly {
            let plan = ModelPlan(ModelPlan.of(root: models).missing.filter { $0.part == .speech })
            return ModelDownloadPlan(missing: plan.parts, requiredFreeBytes: plan.requiredFreeBytes,
                                     downloadBytes: plan.downloadBytes)
        }
        let job = noteID.flatMap { processing.state.jobs[$0] }
        let speakersOnly = job?.kind == .speakersOnly
        let speech: any Transcribing
        if noteID == nil { speech = downloadTranscriber }
        else if let job {
            guard let candidate = try? transcriber.forJob(recognizer: job.recognizer) else {
                return ModelDownloadPlan(missing: [], requiredFreeBytes: 0)
            }
            speech = candidate
        } else { speech = transcriber }
        return ModelDownloadPlan.plan(speech: await speech.assetStatus(locale: Locale(identifier: job?.language ?? settings.speechLanguage)),
                                      speakers: await analyzer.modelStatus(), forNote: noteID != nil,
                                      identifySpeakers: settings.identifySpeakers, speakersOnly: speakersOnly,
                                      speakersInstallBytes: analyzer.modelInstallBytes,
                                      recognizer: speech.recognizer, catalog: ModelPlan.of(root: models))
    }

    func speechLanguage() -> String? { downloadTranscriber.recognizer.usesLanguage ? settings.speechLanguage : nil }

    func usableBytes() async -> Int64 { storage.availableBytes(at: root) }

    func recordConsent(for parts: [ModelPart]) {
        if parts.contains(.speech) { settings.recordConsent() }
        if parts.contains(.speakers) { settings.recordSpeakerConsent() }
    }

    func recordDeclined() { settings.recordDeclined() }

    func transcribe(_ noteID: UUID) async -> TranscribeOutcome {
        await processing.transcribe(noteID, kind: processing.state.jobs[noteID]?.kind ?? .transcribe)
    }

    /// The parts are installed now, one after another, with their progress and failure in
    /// `ProcessingStore.models` (the Settings rows and the download notice).
    func downloadModels(_ parts: [ModelPart]) {
        processing.models.install(parts)
    }

    func askNotificationsOnce() async { await notices.askNotificationsOnce() }
}

