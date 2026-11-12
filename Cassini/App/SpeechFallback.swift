import Foundation
import CassiniEngine
import CassiniNotebook

/// Which recognizer takes over a job whose own could not get its memory or load its model
/// (`TranscriptionCoordinator.Parts.fallbackRecognizer`): the bundled Whistle after Parakeet, when Whistle can run on
/// this device now. For that one job: the person's choice of model in Settings is not touched, and a Whistle or
/// Apple run that fails stays failed.
enum SpeechFallback {
    static func recognizer(for job: Job, transcriber: any Transcribing) async -> String? {
        // A job from before jobs named their recognizer resolves to the device's first one, which may be Parakeet.
        guard (try? transcriber.forJob(recognizer: job.recognizer))?.recognizer == .parakeet,
              let whistle = try? transcriber.forJob(recognizer: SpeechRecognizer.whistle.rawValue),
              whistle.recognizer == .whistle,
              await whistle.unavailability(locale: Locale(identifier: job.language)) == nil else { return nil }
        return SpeechRecognizer.whistle.rawValue
    }
}
