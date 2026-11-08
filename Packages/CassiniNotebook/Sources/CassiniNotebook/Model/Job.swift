import CassiniCore
import Foundation

/// What a job does. Persisted by raw value: never rename one.
public enum JobKind: String, Codable, CaseIterable, Hashable, Sendable {
    case transcribe
    case transcribeAgain
    case speakersOnly
}

/// The state of a note's job (at most one per note). Persisted by raw value: never rename one.
public enum JobState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued, running, paused, failed, needsConsent
}

/// Why a job is paused. Persisted by raw value: never rename one.
public enum PauseReason: String, Codable, CaseIterable, Hashable, Sendable {
    case user, system, memory, interrupted
}

/// Why the queue does not start its next job. Persisted by raw value: never rename one.
public enum QueueHold: String, Codable, CaseIterable, Hashable, Sendable {
    /// Stop from the app; cleared by Continue or any explicit Transcribe or Resume.
    case user
    /// iOS ended the background time; cleared only by Continue or Resume from a visible screen.
    case system
}

/// A model download error, stored inside `JobFailure.download` codes as `DOWNLOAD_<rawValue>`.
public enum DownloadError: String, Codable, CaseIterable, Hashable, Sendable {
    case noConnection = "NO_CONNECTION"
    case interrupted = "INTERRUPTED"
    case notEnoughStorage = "NOT_ENOUGH_STORAGE"
    case fileCheckFailed = "FILE_CHECK_FAILED"
    case install = "INSTALL"
    case hostNotAllowed = "HOST_NOT_ALLOWED"
    /// iOS ended the background time the download ran in.
    case stoppedBySystem = "STOPPED_BY_SYSTEM"
    /// The model host's manifest does not list the model as this build pins it (its id and source hash, or any of its
    /// files): only a newer Cassini can download it, so trying again does not help. iOS only (D4, D53.1).
    case pinUnavailable = "PIN_UNAVAILABLE"
}

/// Why a job or a step of it failed, as a stable code. The app maps each code to its copy; the code is what is stored.
/// The plain codes are Android's core `Failure` names, plus the iOS-only `INTERRUPTED`, `UNSUPPORTED_LANGUAGE` and
/// `RESERVATION_LIMIT`.
public enum JobFailure: Hashable, Sendable {
    case open, large, long, short, audio, wav, stalled, empty, timings, model, space
    /// A model download failed outside a job's own install (Android's core `DOWNLOAD`); see also `download(_:)`.
    case modelDownload
    /// A downloaded model failed its check (`VERIFY`).
    case modelVerify
    /// A verified model could not be put in place (`INSTALL`).
    case modelInstall
    case save, speakers, memory, cancelled, unknown, playback, opusEncoder
    /// The app was closed while the job ran.
    case interrupted
    case unsupportedLanguage
    case reservationLimit
    case download(DownloadError)
    case documentRefused(DocumentState)
    case checkpointMismatch

    public static let downloadPrefix = "DOWNLOAD_"
    public static let documentPrefix = "DOCUMENT_"

    private static let plain: [JobFailure] = [
        .open, .large, .long, .short, .audio, .wav, .stalled, .empty, .timings, .model, .space, .modelDownload,
        .modelVerify, .modelInstall, .save, .speakers, .memory, .cancelled, .unknown, .playback, .opusEncoder,
        .interrupted, .unsupportedLanguage, .reservationLimit, .checkpointMismatch,
    ]

    /// Every failure, one per stored code.
    public static var allCases: [JobFailure] {
        plain + DownloadError.allCases.map(JobFailure.download) + DocumentState.allCases.map(JobFailure.documentRefused)
    }

    public var code: String {
        switch self {
        case .open: "OPEN"
        case .large: "LARGE"
        case .long: "LONG"
        case .short: "SHORT"
        case .audio: "AUDIO"
        case .wav: "WAV"
        case .stalled: "STALLED"
        case .empty: "EMPTY"
        case .timings: "TIMINGS"
        case .model: "MODEL"
        case .space: "SPACE"
        case .modelDownload: "DOWNLOAD"
        case .modelVerify: "VERIFY"
        case .modelInstall: "INSTALL"
        case .save: "SAVE"
        case .speakers: "SPEAKERS"
        case .memory: "MEMORY"
        case .cancelled: "CANCELLED"
        case .unknown: "UNKNOWN"
        case .playback: "PLAYBACK"
        case .opusEncoder: "OPUS_ENCODER"
        case .interrupted: "INTERRUPTED"
        case .unsupportedLanguage: "UNSUPPORTED_LANGUAGE"
        case .reservationLimit: "RESERVATION_LIMIT"
        case .checkpointMismatch: "CHECKPOINT_MISMATCH"
        case .download(let error): Self.downloadPrefix + error.rawValue
        case .documentRefused(let state): Self.documentPrefix + state.name
        }
    }

    public init?(code: String) {
        if let error = Self.downloadError(code) { self = .download(error); return }
        if code.hasPrefix(Self.documentPrefix),
           let state = DocumentState.allCases.first(where: { Self.documentPrefix + $0.name == code }) {
            self = .documentRefused(state); return
        }
        guard let failure = Self.plain.first(where: { $0.code == code }) else { return nil }
        self = failure
    }

    /// The download error of a stored code, or nil when the code is not a download failure.
    public static func downloadError(_ code: String) -> DownloadError? {
        guard code.hasPrefix(downloadPrefix) else { return nil }
        return DownloadError(rawValue: String(code.dropFirst(downloadPrefix.count)))
    }
}

extension JobFailure: Codable {
    /// A code this version does not know reads as `unknown`, so a newer note still opens.
    public init(from decoder: any Decoder) throws {
        self = JobFailure(code: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

/// A queued or past transcription job; `jobs.json` keeps them in `seq` order.
public struct Job: Codable, Hashable, Identifiable, Sendable {
    public var noteID: UUID
    public var seq: Int
    public var kind: JobKind
    public var state: JobState
    public var pauseReason: PauseReason?
    public var failure: JobFailure?
    public var attempts: Int
    public var doneMs: Int64
    public var totalMs: Int64?
    public var words: Int
    /// BCP-47; set only for transcribe kinds.
    public var language: String
    /// Frozen backend for new jobs. Absent in legacy jobs, which retain the legacy recognizer.
    public var recognizer: String?
    public var enqueuedAt: Date
    public var updatedAt: Date

    public var id: UUID { noteID }

    public init(noteID: UUID, seq: Int, kind: JobKind, state: JobState = .queued, pauseReason: PauseReason? = nil,
                failure: JobFailure? = nil, attempts: Int = 0, doneMs: Int64 = 0, totalMs: Int64? = nil, words: Int = 0,
                language: String = "", enqueuedAt: Date, updatedAt: Date? = nil, recognizer: String? = nil) {
        self.noteID = noteID; self.seq = seq; self.kind = kind; self.state = state; self.pauseReason = pauseReason
        self.failure = failure; self.attempts = attempts; self.doneMs = doneMs; self.totalMs = totalMs; self.words = words
        self.recognizer = recognizer
        self.language = language; self.enqueuedAt = enqueuedAt; self.updatedAt = updatedAt ?? enqueuedAt
    }
}

/// The job a note had when it went to Recently Deleted, so Restore can put a queued one back.
public struct TrashedJob: Codable, Hashable, Sendable {
    public var state: JobState
    public var kind: JobKind
    public var recognizer: String?
    public init(state: JobState, kind: JobKind, recognizer: String? = nil) {
        self.state = state; self.kind = kind; self.recognizer = recognizer
    }
}

extension DownloadError {
    /// The failure whose message a download error shows in "Couldn't transcribe" (Android
    /// `ModelInstallOwner.failureOf`): no space, a failed file check and a failed install have their own; the rest
    /// are a failed download. A model the host does not offer as pinned (iOS only) is its own failure, the download
    /// error itself: no plain failure says "update Cassini".
    public var failure: JobFailure {
        switch self {
        case .notEnoughStorage: .space
        case .fileCheckFailed: .modelVerify
        case .install: .modelInstall
        case .noConnection, .interrupted, .hostNotAllowed, .stoppedBySystem: .modelDownload
        case .pinUnavailable: .download(.pinUnavailable)
        }
    }
}
