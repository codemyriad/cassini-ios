import CassiniNotebook

/// The copy for each stored failure code.
extension JobFailure {
    var transcriptionMessage: String {
        switch self {
        case .open: "This audio could not be opened. Try M4A, WAV, MP3, AIFF, or CAF."
        case .save: "The transcript could not be saved. Your audio is kept."
        case .space: "Your device is running low on storage. Free up space, then try again."
        case .long: "This recording is too long to transcribe on this device."
        case .short: "This recording is too short to transcribe."
        case .empty: "No speech was found in this recording."
        case .large: "This file is too large. Choose a file under 4 GB."
        case .audio: "Could not read this audio. The original file has been kept."
        case .wav: "Use a 16-bit PCM WAV, or try M4A, MP3, AIFF, or CAF."
        case .stalled: "Audio decoding stalled. Try another file."
        case .timings: "Word timing could not be read. Try transcribing again."
        case .modelDownload: "Model download failed. Check your connection and retry."
        case .modelVerify: "Model verification failed. Please download it again."
        case .modelInstall: "Could not save the model. Free some space and retry."
        case .memory: "Not enough memory. Try a shorter clip and close other apps."
        case .cancelled: "Operation cancelled."
        case .playback: "Playback is unavailable for this file."
        case .opusEncoder: "This device has no Opus encoder. It can open existing documents, but cannot create new Cassini files."
        case .model: "On-device transcription is unavailable on this device. Your audio is saved and can still be played or exported."
        case .speakers: "Speaker analysis could not finish. Your transcript is saved. You can retry from Speakers."
        case .interrupted: "Transcription was interrupted. Keep Cassini open, then tap Transcribe to start again."
        case .unknown: "Transcription could not finish. Your audio is saved. Try again."
        case .unsupportedLanguage: "Apple’s on-device speech model does not support this language. Choose another language in Settings."
        case .reservationLimit: "The system cannot reserve another speech language. Try a language already installed on this device."
        case .download: "The speech model could not be downloaded. Check your connection and storage, then try again."
        case .documentRefused: "This document cannot take a new transcript."
        case .checkpointMismatch: "Saved progress no longer matches the audio. Start over to transcribe it again."
        }
    }

    var speakerAnalysisMessage: String {
        self == .empty ? "No speakers were detected. You can assign passages manually." : JobFailure.speakers.transcriptionMessage
    }
}

extension UnplayableReason {
    var message: String {
        switch self {
        case .interrupted: "This recording can’t be played. Cassini closed before the recording was saved. You can still save the file."
        case .unsupportedFormat: "This device cannot play the imported Opus container. Its verified transcript is available, and the original Cassini document is preserved for sharing."
        }
    }
}

extension Note {
    /// Why the audio cannot be played, or nil when it can.
    var playbackProblem: String? {
        if case .unplayable(let reason) = audio { reason.message } else { nil }
    }
}
