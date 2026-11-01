import Foundation
import CassiniNotebook

/// The copy for each stored failure code, from the Failures table. The English and Italian are Android's (`error_*`)
/// with iOS's own limits and names (LONG: about 16 hours of speech, Share original audio), except where the platform
/// changes what the message has to say; docs/differences.md lists those codes (OPEN, SAVE, SPACE, AUDIO, WAV, MODEL,
/// SPEAKERS) and the iOS-only ones.
extension JobFailure {
    var transcriptionMessage: String {
        switch self {
        case .open: String(localized: "This audio could not be opened. Try M4A, WAV, MP3, AIFF, or CAF.", table: "Failures")
        case .save: String(localized: "The transcript could not be saved.", table: "Failures")
        case .space: String(localized: "Your device is running low on storage. Free up space, then try again.", table: "Failures")
        case .long:
            String(localized: "This recording is too long to transcribe: one transcript holds up to 36 hours of audio and about 16 hours of speech. You can still play it, and share the audio file with Share original audio.",
                   table: "Failures")
        case .short: String(localized: "Choose at least 200 milliseconds of audio.", table: "Failures")
        case .empty: String(localized: "This recording contains no audio samples.", table: "Failures")
        case .large: String(localized: "This file is too large. Choose a file under 4 GB.", table: "Failures")
        case .audio: String(localized: "Could not read this audio. The original file has been kept.", table: "Failures")
        case .wav: String(localized: "Use a 16-bit PCM WAV, or try M4A, MP3, AIFF, or CAF.", table: "Failures")
        case .stalled: String(localized: "Audio decoding stalled. Try another file.", table: "Failures")
        case .timings: String(localized: "Word timing could not be read. Try transcribing again.", table: "Failures")
        case .modelDownload: String(localized: "Model download failed. Check your connection and retry.", table: "Failures")
        case .modelVerify: String(localized: "Model verification failed. Please download it again.", table: "Failures")
        case .modelInstall: String(localized: "Could not save the model. Free some space and retry.", table: "Failures")
        case .memory: String(localized: "Not enough memory. Try a shorter clip and close other apps.", table: "Failures")
        case .cancelled: String(localized: "Operation cancelled.", table: "Failures")
        case .playback: String(localized: "Playback is unavailable for this file.", table: "Failures")
        case .opusEncoder:
            String(localized: "This device has no Opus encoder. It can open existing documents, but cannot create new Cassini files.",
                   table: "Failures")
        case .model:
            String(localized: "On-device transcription is unavailable on this device. Your audio can still be played or exported.",
                   table: "Failures")
        case .speakers:
            String(localized: "Speaker analysis could not finish. Your transcript is saved. You can retry from Speakers.",
                   table: "Failures")
        case .interrupted:
            String(localized: "Transcription was interrupted. Keep Cassini open, then tap Transcribe to start again.",
                   table: "Failures")
        case .unknown: String(localized: "Something went wrong. Please try again.", table: "Failures")
        case .unsupportedLanguage:
            String(localized: "Apple’s on-device speech model does not support this language. Choose another language in Settings.",
                   table: "Failures")
        case .reservationLimit:
            String(localized: "The system cannot reserve another speech language. Try a language already installed on this device.",
                   table: "Failures")
        case .download(.pinUnavailable):
            String(localized: "This version of the model is no longer offered for download. Update Cassini, then try again.",
                   table: "Failures")
        case .download(let error): error.failure.transcriptionMessage
        case .documentRefused(.unverified):
            String(localized: "The audio of this document could not be checked, so a new version cannot be added.",
                   table: "Failures")
        case .documentRefused(.unknownFormat):
            String(localized: "This document has a newer Cassini format, so a new version cannot be added here.",
                   table: "Failures")
        case .documentRefused: String(localized: "This document cannot take a new transcript.", table: "Failures")
        case .checkpointMismatch:
            String(localized: "Saved progress no longer matches the audio. Start over to transcribe it again.", table: "Failures")
        }
    }

    var speakerAnalysisMessage: String {
        self == .empty
            ? String(localized: "No speakers were detected. You can assign passages manually.", table: "Failures")
            : JobFailure.speakers.transcriptionMessage
    }
}

extension UnplayableReason {
    /// The UNPLAYABLE banner's body: nil for Android's one reason, which the banner's own copy says.
    var bannerText: String? {
        switch self {
        case .interrupted: nil
        case .unsupportedFormat:
            String(localized: "This device cannot play the imported Opus container. Its verified transcript is available, and the original Cassini document is preserved for sharing.",
                   table: "Failures")
        }
    }
}

/// Why something failed, as a sentence on screen: the packages' own errors from the Failures table, any other in the
/// system's words (Foundation's errors are localized by the system).
enum FailureReason {
    static func of(_ error: any Error) -> String {
        switch error {
        case RepositoryError.invalidDocument:
            String(localized: "This note’s details are not supported or are damaged. Its files have been kept.", table: "Failures")
        default: error.localizedDescription
        }
    }
}
