import Foundation
import CassiniEngine

/// What a transcription job needs from the app: its settings when it starts, and the voices to match speakers with.
@MainActor final class AppJobHost: TranscriptionJobHost {
    private let settings: SettingsStore
    private let voices: VoicesStore

    init(settings: SettingsStore, voices: VoicesStore) { self.settings = settings; self.voices = voices }

    func jobSettings() async -> JobSettings {
        JobSettings(allowSpeechDownload: settings.downloadsAllowed, identifySpeakers: settings.identifySpeakers,
                    allowSpeakerDownload: settings.speakerDownloadsAllowed, voicesGeneration: settings.voicesGeneration)
    }

    func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
        try await voices.applySpeakerAnalysis(analysis, to: noteID, generation: generation)
    }
}
