import Foundation

public struct RecoveredRecording: Hashable, Sendable {
    public var noteID: UUID
    public var recoveredAt: Date
    public var duration: TimeInterval
    public init(noteID: UUID, recoveredAt: Date, duration: TimeInterval) {
        self.noteID = noteID; self.recoveredAt = recoveredAt; self.duration = duration
    }
}

public enum ImportFailureKind: Hashable, Sendable {
    case tooLarge
    case noSpace(bytesNeeded: Int64)
    case cannotOpen
    case cannotSave
}

public struct ImportFailureFact: Hashable, Sendable {
    public var displayName: String
    public var kind: ImportFailureKind
    public var at: Date
    public init(displayName: String, kind: ImportFailureKind, at: Date) { self.displayName = displayName; self.kind = kind; self.at = at }
}

public enum ModelPart: String, Codable, CaseIterable, Hashable, Sendable {
    /// Apple's speech assets.
    case speech
    /// Telling speakers apart.
    case speakers
    /// Recognising saved voices.
    case voices
}

public struct DownloadFact: Hashable, Sendable {
    public var part: ModelPart
    /// Download progress, or nil while checking.
    public var fraction: Double?
    public var failure: DownloadError?
    public var at: Date
    public init(part: ModelPart, fraction: Double? = nil, failure: DownloadError? = nil, at: Date) {
        self.part = part; self.fraction = fraction; self.failure = failure; self.at = at
    }
}

/// Everything the banners are built from. The coordinators publish facts; the notice rules order and word them.
public struct NoticeFacts: Hashable, Sendable {
    /// Recordings recovered after Cassini closed unexpectedly, oldest first.
    public var recovered: [RecoveredRecording]
    /// Note directories whose metadata could not be read; they are kept on disk.
    public var unreadableNotes: Int
    /// The library itself could not be opened.
    public var libraryUnavailable: Bool
    public var voicesUnavailable: Bool
    public var queueHold: QueueHold?
    public var waitingJobs: Int
    /// Notes whose last job failed, with the failure.
    public var failedJobs: [UUID: JobFailure]
    /// Display names of the files being imported, in order.
    public var importing: [String]
    public var importFailure: ImportFailureFact?
    public var download: DownloadFact?
    public var notificationsOff: Bool

    public init(recovered: [RecoveredRecording] = [], unreadableNotes: Int = 0, libraryUnavailable: Bool = false,
                voicesUnavailable: Bool = false, queueHold: QueueHold? = nil, waitingJobs: Int = 0,
                failedJobs: [UUID: JobFailure] = [:], importing: [String] = [], importFailure: ImportFailureFact? = nil,
                download: DownloadFact? = nil, notificationsOff: Bool = false) {
        self.recovered = recovered; self.unreadableNotes = unreadableNotes; self.libraryUnavailable = libraryUnavailable
        self.voicesUnavailable = voicesUnavailable; self.queueHold = queueHold; self.waitingJobs = waitingJobs
        self.failedJobs = failedJobs; self.importing = importing; self.importFailure = importFailure
        self.download = download; self.notificationsOff = notificationsOff
    }
}
