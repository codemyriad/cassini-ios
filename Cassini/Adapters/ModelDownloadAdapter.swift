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
    private let platform: PlatformFacts

    /// `root` is where the notes are, `models` where the pinned models are installed.
    init(settings: SettingsStore, processing: ProcessingStore, transcriber: any Transcribing,
         analyzer: any SpeakerAnalyzing, storage: any StorageProbe, notices: NoticeCenter, root: URL, models: URL,
         platform: PlatformFacts, downloadTranscriber: (any Transcribing)? = nil, speechOnly: Bool = false) {
        self.settings = settings; self.processing = processing; self.transcriber = transcriber
        self.downloadTranscriber = downloadTranscriber ?? transcriber; self.speechOnly = speechOnly
        self.analyzer = analyzer; self.storage = storage; self.notices = notices; self.root = root; self.models = models
        self.platform = platform
    }

    /// `ModelDownloadPlan.plan` over the speech model of the chosen language and the speaker models' status, for the
    /// note's job, with the sizes of what the catalog still has to install.
    func plan(for noteID: UUID?, part: ModelPart?) async -> ModelDownloadPlan {
        if speechOnly {
            let plan = ModelPlan((await Self.catalog(at: models)).missing.filter { $0.part == .speech })
            return ModelDownloadPlan(missing: plan.parts, requiredFreeBytes: plan.requiredFreeBytes,
                                     downloadBytes: plan.downloadBytes)
        }
        let context: SpeechDownloadContext?
        if let noteID { context = await processing.coordinator?.modelDownloadContext(for: noteID) }
        else { context = nil }
        let speakersOnly = context?.kind == .speakersOnly
        let speech: any Transcribing
        if noteID == nil { speech = downloadTranscriber }
        else if let context {
            guard let candidate = try? transcriber.forJob(recognizer: context.recognizer) else {
                return ModelDownloadPlan(missing: [], requiredFreeBytes: 0)
            }
            speech = candidate
        } else { speech = transcriber }
        let sizes = await Self.installBytes(speech: speech, analyzer: analyzer)
        return ModelDownloadPlan.plan(speech: await speech.assetStatus(locale: Locale(identifier: context?.language ?? settings.speechLanguage)),
                                      speakers: await analyzer.modelStatus(), forNote: noteID != nil,
                                      identifySpeakers: settings.identifySpeakers, speakersOnly: speakersOnly,
                                      speakersInstallBytes: sizes.speakers, speechInstallBytes: sizes.speech,
                                      recognizer: speech.recognizer, catalog: await Self.catalog(at: models), requestedPart: part)
    }

    func speechLanguage(for noteID: UUID?) async -> String? {
        guard let noteID else { return speechLanguage() }
        if let context = await processing.coordinator?.modelDownloadContext(for: noteID),
           let speech = try? transcriber.forJob(recognizer: context.recognizer) {
            return platform.asksForSpeechLanguage(speech.recognizer) ? context.language : nil
        }
        return platform.asksForSpeechLanguage(transcriber.recognizer) ? settings.speechLanguage : nil
    }

    func speechLanguage() -> String? { platform.asksForSpeechLanguage(downloadTranscriber.recognizer) ? settings.speechLanguage : nil }

    func usableBytes() async -> Int64 {
        await Self.available(storage: storage, root: root)
    }

    @concurrent private static func installBytes(speech: any Transcribing, analyzer: any SpeakerAnalyzing) async
        -> (speech: Int64, speakers: Int64) {
        (speech.assetInstallBytes, analyzer.modelInstallBytes)
    }

    @concurrent private static func catalog(at root: URL) async -> ModelPlan { ModelPlan.of(root: root) }
    @concurrent private static func available(storage: any StorageProbe, root: URL) async -> Int64 {
        storage.availableBytes(at: root)
    }

    func recordConsent(for parts: [ModelPart]) {
        if parts.contains(.speech) { settings.recordConsent() }
        if parts.contains(.speakers) { settings.recordSpeakerConsent() }
    }

    func recordDeclined() { settings.recordDeclined() }

    func recordDeclined(part: ModelPart) {
        switch part {
        case .speakers: settings.identifySpeakers = false
        case .voices: settings.recogniseSavedVoices = false
        case .speech: break
        }
    }

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

