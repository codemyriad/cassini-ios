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
    /// The free space the install's check asked for; "Free about N MB" when it failed with `notEnoughStorage`.
    public var requiredFreeBytes: Int64
    public var at: Date
    public init(part: ModelPart, fraction: Double? = nil, failure: DownloadError? = nil, requiredFreeBytes: Int64 = 0,
                at: Date) {
        self.part = part; self.fraction = fraction; self.failure = failure; self.requiredFreeBytes = requiredFreeBytes
        self.at = at
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
    /// Queued jobs, not counting the running one.
    public var waitingJobs: Int
    /// A job runs, or a download runs on its own.
    public var jobRunning: Bool
    /// The user agreed to download the speech model.
    public var consented: Bool
    /// Notes whose last job failed, with the failure.
    public var failedJobs: [UUID: JobFailure]
    /// Display names of the files being imported, in order.
    public var importing: [String]
    public var importFailure: ImportFailureFact?
    public var download: DownloadFact?
    public var notificationsOff: Bool

    public init(recovered: [RecoveredRecording] = [], unreadableNotes: Int = 0, libraryUnavailable: Bool = false,
                voicesUnavailable: Bool = false, queueHold: QueueHold? = nil, waitingJobs: Int = 0,
                jobRunning: Bool = false, consented: Bool = true, failedJobs: [UUID: JobFailure] = [:],
                importing: [String] = [], importFailure: ImportFailureFact? = nil, download: DownloadFact? = nil, notificationsOff: Bool = false) {
        self.recovered = recovered; self.unreadableNotes = unreadableNotes; self.libraryUnavailable = libraryUnavailable
        self.voicesUnavailable = voicesUnavailable; self.queueHold = queueHold; self.waitingJobs = waitingJobs
        self.jobRunning = jobRunning; self.consented = consented
        self.failedJobs = failedJobs; self.importing = importing; self.importFailure = importFailure
        self.download = download; self.notificationsOff = notificationsOff
    }
}

/// What only the Library screen knows, added to `NoticeFacts` for its banners and empty states.
public struct LibraryFacts: Hashable, Sendable {
    /// The notes have not been read yet.
    public var loading: Bool
    /// Notes not in Recently Deleted.
    public var liveNotes: Int
    /// The search text; empty when not searching.
    public var query: String
    /// How many notes the search found; nil while it has not answered.
    public var results: Int?
    /// Some note has audio but no transcript.
    public var audioOnly: Bool
    /// The library could not be opened: not the same as an empty one.
    public var unavailable: Bool

    public init(loading: Bool = false, liveNotes: Int = 0, query: String = "", results: Int? = nil,
                audioOnly: Bool = false, unavailable: Bool = false) {
        self.loading = loading; self.liveNotes = liveNotes; self.query = query; self.results = results
        self.audioOnly = audioOnly; self.unavailable = unavailable
    }
}
