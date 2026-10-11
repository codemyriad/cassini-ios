import AVFoundation
import Speech
import CassiniNotebook

actor SpeechService {
    enum Failure: LocalizedError {
        case unavailable, unsupportedLanguage, downloadConsent, reservationLimit
        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device transcription is unavailable on this device. Your audio is saved and can still be played or exported."
            case .unsupportedLanguage: "Apple’s on-device speech model does not support this language. Choose another language in Settings."
            case .downloadConsent: "A speech model is needed. Allow model downloads in Settings, then try again. Audio stays on this device."
            case .reservationLimit: "The system cannot reserve another speech language. Try a language already installed on this device."
            }
        }
    }
    func transcribe(url: URL, locale identifier: String, allowDownload: Bool,
                    progress: @escaping @MainActor @Sendable (String, Double?) -> Void) async throws -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw Failure.unsupportedLanguage
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            guard allowDownload else { throw Failure.downloadConsent }
            await progress("Preparing speech model…", nil)
            guard try await AssetInventory.reserve(locale: locale) else { throw Failure.reservationLimit }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await progress("Transcribing on this device…", 0)
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
                    group.addTask {
                        do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
                        catch { await analyzer.cancelAndFinishNow(); throw error }
                        return []
                    }
                    group.addTask {
                        var segments: [TranscriptSegment] = []
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let start = result.range.start.seconds
                            let end = result.range.end.seconds
                            var words: [TimedWord] = []
                            for run in result.text.runs {
                                let range = run.audioTimeRange
                                words.append(TimedWord(text: String(result.text[run.range].characters),
                                    start: range?.start.seconds ?? (words.last?.end ?? start),
                                    end: range?.end.seconds ?? (words.last?.end ?? start)))
                            }
                            segments.append(TranscriptSegment(text: text, start: start, end: end, words: words))
                            await progress("Transcribing on this device…", min(0.99, end / max(1, duration)))
                        }
                        return segments
                    }
                    var transcript: [TranscriptSegment] = []
                    for try await result in group { if !result.isEmpty { transcript = result } }
                    return transcript.sorted { $0.start < $1.start }
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
