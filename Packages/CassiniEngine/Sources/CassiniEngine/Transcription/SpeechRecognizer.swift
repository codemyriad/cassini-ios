import Foundation
import CassiniNotebook

/// The recognizer that transcribes a job: Parakeet Ultra, or Apple's SpeechTranscriber on devices that cannot hold
/// Ultra (decision D2, an iOS platform constraint; Android has no fallback).
public enum SpeechRecognizer: String, Hashable, Sendable {
    case parakeet
    case appleSpeech
    case whistle

    /// The checkpoint's `model` for a run in `language`: Parakeet's pinned revision (Android's `model` member), or the
    /// Apple module with the language, whose words depend on it.
    public func checkpointModel(language: String) -> String {
        switch self {
        case .parakeet: ModelCatalog.parakeetRevision
        case .appleSpeech: CheckpointState.appleModel(language: language)
        case .whistle: "whistle b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb; needle 93e88ede867e4311c39151285e74df513e4b835b; fir97-hpf100-silero6.2.1-ort1.27.1-gate-v1"
        }
    }

    /// Recover identity only from a known checkpoint model family; the run still validates the full model pin.
    public static func fromCheckpoint(model: String) -> SpeechRecognizer? {
        if model.hasPrefix("whistle ") { return .whistle }
        if model == ModelCatalog.parakeetRevision { return .parakeet }
        if model.hasPrefix(CheckpointState.appleModel(language: "")) { return .appleSpeech }
        return nil
    }

    /// Whether the recognizer takes a language. Parakeet hears it: its jobs and checkpoints carry `""`, and its words
    /// are written as `und` (`TranscriptLanguage`).
    public var usesLanguage: Bool { self == .appleSpeech }
}

/// Which recognizer this device gets (decision D2). Pure, so the rule is tested on the host; Apple eligibility is
/// checked again for the requested locale at admission and execution.
public enum SpeechCapability {
    /// The least physical memory a device must report for Parakeet Ultra: 3.25 GiB, which admits 4 GB devices and no
    /// 3 GB one. Measured on devices on 2026-11-11 (iPhone 11, 12 and 13 and the 2022 iPad, all 4 GB): they report 3665
    /// to 3854 MiB, iOS lets the app hold 2098 MiB (2867 on the iPad), and twelve full 28 s windows with both speaker
    /// models loaded peaked at 1437 to 1535 MiB, at most 69 % of that. A 3 GB device cannot report more than 3072 MiB
    /// and has not been measured.
    public static let minimumPhysicalMemory: UInt64 = 13 << 28

    /// Whether a device with `physicalMemory` bytes can hold Ultra.
    public static func parakeetCapable(physicalMemory: UInt64) -> Bool { physicalMemory >= minimumPhysicalMemory }

    /// A supported downloadable Apple model remains eligible, but cannot decode until its assets are installed.
    /// The caller must probe hardware, the equivalent locale and asset status; RAM alone cannot select Apple.
    public static func choose(linked: Bool, capable: Bool, apple: AppleSpeechCapability) -> SpeechRecognizer? {
        if linked && capable { return .parakeet }
        return apple.failure == nil ? .appleSpeech : nil
    }

}

/// Public Apple availability checks expressed without importing Speech, for capability and admission tests.
public struct AppleSpeechCapability: Hashable, Sendable {
    public var hardwareAvailable: Bool
    public var localeSupported: Bool
    public var assets: ModelPartStatus
    public init(hardwareAvailable: Bool, localeSupported: Bool, assets: ModelPartStatus) {
        self.hardwareAvailable = hardwareAvailable; self.localeSupported = localeSupported; self.assets = assets
    }
    public var failure: JobFailure? {
        if !hardwareAvailable { return .model }
        if !localeSupported { return .unsupportedLanguage }
        return assets == .unsupported ? .model : nil
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
/// window. Below the figure the run fails with `MEMORY` rather than be ended by iOS. The figures are from devices
/// (2026-11-11, four 4 GB devices and a 6 GB one): the load and the first full 28 s window took 955 to 995 MiB, the
/// next three windows 280 to 340 MiB more, and later windows nothing.
public enum ParakeetMemory {
    /// What a run needs from before the load until its memory stops growing (1250 to 1335 MiB measured), so that a run
    /// that starts also passes the check before its second window.
    public static let beforeLoadBytes: Int64 = 1_450 << 20
    /// What the windows after the first can still add once the recognizer is loaded (up to 340 MiB measured).
    public static let beforeWindowBytes: Int64 = 400 << 20

    /// Whether `availableBytes` is enough for the next step; nil (the system does not tell, as on a Mac or the
    /// simulator) always is.
    public static func allows(availableBytes: Int64?, loaded: Bool) -> Bool {
        guard let availableBytes, availableBytes > 0 else { return true }
        return availableBytes >= (loaded ? beforeWindowBytes : beforeLoadBytes)
    }
}
