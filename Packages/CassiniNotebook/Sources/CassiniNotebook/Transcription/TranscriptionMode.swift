import Foundation

/// Recording-time and post-Stop transcription policy (`D-1117`, `D109`, `D111`).
///
/// The shipped default is `.transcribeWhileRecording` (`D111`). Persisted values accept the canonical Swift names as
/// well as the Python/GNOME (`snake_case`) and Kotlin/Android (`SCREAMING_SNAKE_CASE`) tokens from the shared contract;
/// any unknown, empty, null, wrong-case, or non-string value resolves deterministically to `.transcribeWhileRecording`.
public enum TranscriptionMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Run zero native models during recording and do not auto-enqueue transcription on Stop.
    case recordOnly
    /// Zero models during recording; auto-enqueue batch transcription on Stop.
    case afterStop
    /// Default shipped behaviour (`D111`): follow committed `.caf` frames read-only during recording to populate
    /// resumable checkpoints, then finalize on Stop.
    case transcribeWhileRecording

    public static let defaultMode: TranscriptionMode = .transcribeWhileRecording

    /// Whether a completed recording should auto-enqueue transcription on Stop.
    public var autoEnqueueOnStop: Bool {
        switch self {
        case .recordOnly: false
        case .afterStop, .transcribeWhileRecording: true
        }
    }

    /// Whether recording-time precomputation is permitted by this mode.
    public var allowsPrecomputeDuringRecording: Bool {
        self == .transcribeWhileRecording
    }

    /// Resolves a persisted or external raw value to a canonical `TranscriptionMode`.
    /// Returns `(mode, fellBackToDefault)` matching `vectors/head-start/transcription-mode-vectors.json`.
    public static func resolve(_ raw: Any?) -> (mode: TranscriptionMode, fellBackToDefault: Bool) {
        guard let token = raw as? String else { return (defaultMode, true) }
        switch token {
        case "recordOnly", "record_only", "RECORD_ONLY":
            return (.recordOnly, false)
        case "afterStop", "after_stop", "AFTER_STOP":
            return (.afterStop, false)
        case "transcribeWhileRecording", "transcribe_while_recording", "TRANSCRIBE_WHILE_RECORDING":
            return (.transcribeWhileRecording, false)
        default:
            return (defaultMode, true)
        }
    }
}

/// Deterministic recording-time and Stop-time policy evaluation for `TranscriptionMode`.
public struct TranscriptionModePolicy: Equatable, Sendable {
    public let resolvedMode: TranscriptionMode
    public let fellBackToDefault: Bool
    public let spawnWorkerDuringRecording: Bool
    public let autoEnqueueOnStop: Bool
    public let savedTranscriptStateOnStop: String
    public let enqueueOnManualRequest: Bool
    public let preemptActiveFollower: Bool

    public static func evaluate(
        rawMode: Any?,
        hasForegroundSavedJob: Bool = false,
        manualTranscribeRequested: Bool = false,
        platformSupportsPrecompute: Bool = true
    ) -> TranscriptionModePolicy {
        let (mode, fellBack) = TranscriptionMode.resolve(rawMode)
        let spawnWorker = mode == .transcribeWhileRecording
            && !hasForegroundSavedJob
            && !manualTranscribeRequested
            && platformSupportsPrecompute
        let autoEnqueue = mode.autoEnqueueOnStop
        return TranscriptionModePolicy(
            resolvedMode: mode,
            fellBackToDefault: fellBack,
            spawnWorkerDuringRecording: spawnWorker,
            autoEnqueueOnStop: autoEnqueue,
            savedTranscriptStateOnStop: autoEnqueue ? "queued" : "none",
            enqueueOnManualRequest: manualTranscribeRequested,
            preemptActiveFollower: manualTranscribeRequested || hasForegroundSavedJob
        )
    }
}
