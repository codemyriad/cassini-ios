import Foundation
import CassiniNotebook

/// The recognizer that transcribes a job: Parakeet Ultra, or Apple's SpeechTranscriber on devices that cannot hold
/// Ultra (decision D2, an iOS platform constraint; Android has no fallback).
public enum SpeechRecognizer: String, Hashable, Sendable {
    case parakeet
    case appleSpeech

    /// The checkpoint's `model` for a run in `language`: Parakeet's pinned revision (Android's `model` member), or the
    /// Apple module with the language, whose words depend on it.
    public func checkpointModel(language: String) -> String {
        switch self {
        case .parakeet: ModelCatalog.parakeetRevision
        case .appleSpeech: CheckpointState.appleModel(language: language)
        }
    }

    /// Whether the recognizer takes a language. Parakeet hears it: its jobs and checkpoints carry `""`, and its words
    /// are written as `und` (`TranscriptLanguage`).
    public var usesLanguage: Bool { self == .appleSpeech }
}

/// Which recognizer this device gets (decision D2). Pure, so the rule is tested on the host; the app asks it once at
/// launch with what the device reports.
public enum SpeechCapability {
    /// The least physical memory a device needs for Parakeet Ultra. **Provisional until the WP0 device gate:** on the
    /// simulator one 28 s window peaked at 0.96 to 1.1 GiB (docs ultra-wp0-results, the Pixel 8 measured 1138 MiB), and
    /// the gate asks for that peak to stay under about 70 % of the jetsam limit. 6 GB iPhones (which report a little
    /// under 6 GiB) clear that with room; 4 GB ones are kept on Apple Speech until a device says otherwise.
    public static let minimumPhysicalMemory: UInt64 = 5 << 30

    /// Whether a device with `physicalMemory` bytes can hold Ultra.
    public static func parakeetCapable(physicalMemory: UInt64) -> Bool { physicalMemory >= minimumPhysicalMemory }

    /// Parakeet when the native runtime is linked, its model is installed and the device can hold it; else Apple Speech.
    public static func choose(linked: Bool, installed: Bool, capable: Bool) -> SpeechRecognizer {
        linked && installed && capable ? .parakeet : .appleSpeech
    }
}

/// What a Parakeet run asks the installer for before it decodes (Android's `TranscriptionJob.installModels`).
public enum ParakeetModels {
    /// SPEECH when Ultra is missing. Also SPEECH when only its speech detector is missing and the device is online:
    /// the installer then fetches the detector alone, best effort, as 0.1.0 retried it at every start. Nothing when
    /// both are installed, or offline with only the detector missing (the run cuts at quiet points).
    public static func request(speechReady: Bool, detectorReady: Bool, online: Bool) -> Set<ModelPart> {
        !speechReady || (!detectorReady && online) ? [.speech] : []
    }
}

/// The memory check of a Parakeet run (plan WP4): `os_proc_available_memory()` before the model loads and before each
/// window. Below the figure the run fails with `MEMORY` rather than be ended by iOS. **Provisional until the WP0 device
/// gate**, from the simulator: a loaded recognizer holds about 570 MiB and a 28 s window peaks at about 1.1 GiB.
public enum ParakeetMemory {
    /// What the load and the first window need on top of what Cassini already holds.
    public static let beforeLoadBytes: Int64 = 1_200 << 20
    /// What one more window needs once the recognizer is loaded.
    public static let beforeWindowBytes: Int64 = 640 << 20

    /// Whether `availableBytes` is enough for the next step; nil (the system does not tell, as on a Mac or the
    /// simulator) always is.
    public static func allows(availableBytes: Int64?, loaded: Bool) -> Bool {
        guard let availableBytes, availableBytes > 0 else { return true }
        return availableBytes >= (loaded ? beforeWindowBytes : beforeLoadBytes)
    }
}
