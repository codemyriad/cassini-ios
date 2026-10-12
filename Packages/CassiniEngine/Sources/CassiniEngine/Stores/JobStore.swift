import Foundation
import CassiniNotebook

/// The durable transcription queue: at most one job per note, first in first out by `seq`, at most one running.
/// Every change is one atomic write of `jobs.json`, made before the call returns; a failed write leaves the queue in
/// memory as it was.
///
/// A `jobs.json` that cannot be read is never overwritten: an unreadable one is moved aside and the queue starts empty;
/// one written by a newer Cassini stays as it is and the queue takes no writes in this run.
public actor JobStore {
    public enum Failure: Error, Hashable, Sendable {
        /// `jobs.json` was written by a newer version of Cassini. It is kept as it is; nothing is queued in this run.
        case newerVersion(Int)
        /// `jobs.json` could not be read. It was moved to `movedTo` and the queue starts empty; when it could not be
        /// moved (nil), nothing is queued in this run.
        case unreadable(movedTo: URL?)
        /// The queue takes no writes in this run (see `newerVersion` and `unreadable`).
        case readOnly
    }

    private let repository: JobRepository
    private var jobs: [UUID: Job] = [:]
    /// False when the stored queue could not be read and must not be overwritten.
    public private(set) var isWritable = true

    public init(repository: JobRepository) {
        self.repository = repository
    }

    /// Reads the queue from disk, replacing what is in memory. On a `Failure` the queue in memory is empty: after
    /// `unreadable(movedTo:)` with a place it may be written, otherwise it takes no writes (`isWritable` is false).
    @discardableResult public func load(now: Date = .now) throws -> [Job] {
        let stored: [Job]
        do {
            stored = try repository.load()
        } catch JobRepository.Failure.unsupportedVersion(let version) {
            jobs = [:]
            isWritable = false
            throw Failure.newerVersion(version)
        } catch {
            jobs = [:]
            let movedTo = try? repository.moveAside(at: now)
            isWritable = movedTo != nil
            throw Failure.unreadable(movedTo: movedTo)
        }
        jobs = Dictionary(stored.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        isWritable = true
        return all()
    }

    /// In `seq` order.
    public func all() -> [Job] { jobs.values.sorted { $0.seq < $1.seq } }

    public func job(_ noteID: UUID) -> Job? { jobs[noteID] }

    /// Puts the note's job at the back of the queue. A queued or running job is left as it is; any other job goes to
    /// the back with no failure, pause reason or automatic attempts, keeping the numbers of its saved progress. A nil
    /// `language` keeps the job's language.
    ///
    /// With `waitingForConsent` the job is written as `needsConsent` in the same write ("Ready to transcribe").
    @discardableResult
    public func enqueue(_ noteID: UUID, kind: JobKind, language: String?, now: Date,
                        waitingForConsent: Bool = false) throws -> Job {
        if let existing = jobs[noteID], existing.state == .queued || existing.state == .running { return existing }
        var job = jobs[noteID]?.requeued(seq: nextSeq, kind: kind, language: language, now: now)
            ?? Job(noteID: noteID, seq: nextSeq, kind: kind, language: language ?? "", enqueuedAt: now)
        if waitingForConsent { job.state = .needsConsent }
        try write([job])
        return job
    }

    /// Restore of a note whose job was queued when it went to Recently Deleted: back to the queue at the back. A new
    /// job takes the numbers of `checkpoint`, which stayed in `work/` meanwhile. A running job is left alone.
    @discardableResult
    public func requeueAtBack(_ noteID: UUID, kind: JobKind, language: String, checkpoint: CheckpointStatus,
                              now: Date) throws -> Job? {
        if let existing = jobs[noteID] {
            guard existing.state != .running else { return existing }
            let job = existing.requeued(seq: nextSeq, kind: kind, language: nil, now: now)
            try write([job])
            return job
        }
        let job = Job(noteID: noteID, seq: nextSeq, kind: kind, language: language, enqueuedAt: now)
            .withNumbers(of: checkpoint)
        try write([job])
        return job
    }

    /// Marks the first queued job running, unless a job runs already or there is none. Jobs of `skipped` notes
    /// (those in Recently Deleted) are passed over.
    public func claimNext(now: Date, skipping skipped: Set<UUID> = []) throws -> Job? {
        guard !jobs.values.contains(where: { $0.state == .running }),
              var job = all().first(where: { $0.state == .queued && !skipped.contains($0.noteID) }) else { return nil }
        job.state = .running
        job.updatedAt = now
        try write([job])
        return job
    }

    /// Applies `change` to the note's job and writes it, keeping its note and `seq`. Nil when there is no such job.
    @discardableResult
    public func transition(_ noteID: UUID, now: Date, _ change: @Sendable (inout Job) -> Void) throws -> Job? {
        guard let current = jobs[noteID] else { return nil }
        var job = current
        change(&job)
        job.noteID = current.noteID
        job.seq = current.seq
        guard job != current else { return current }
        job.updatedAt = now
        try write([job])
        return job
    }

    /// Writes every job of `changed` and drops the jobs of `removing` in one atomic write, each changed job keeping the
    /// `seq` it has; jobs that are not stored are ignored.
    public func replace(_ changed: [Job], removing: [UUID] = []) throws {
        let known = changed.filter { jobs[$0.noteID] != nil }
        let gone = removing.filter { jobs[$0] != nil }
        guard !known.isEmpty || !gone.isEmpty else { return }
        try write(known, removing: gone)
    }

    /// `replace` in memory only, for a repair that could not be written: the queue goes on from the repaired jobs, and
    /// the next write saves them with its own change.
    public func assume(_ changed: [Job], removing: [UUID] = []) {
        for job in changed where jobs[job.noteID] != nil { jobs[job.noteID] = job }
        for id in removing { jobs[id] = nil }
    }

    public func remove(_ noteID: UUID) throws {
        guard jobs[noteID] != nil else { return }
        try write([], removing: [noteID])
    }

    private var nextSeq: Int { (jobs.values.map(\.seq).max() ?? 0) + 1 }

    private func write(_ changed: [Job], removing: [UUID] = []) throws {
        guard isWritable else { throw Failure.readOnly }
        var updated = jobs
        for job in changed { updated[job.noteID] = job }
        for id in removing { updated[id] = nil }
        try repository.save(Array(updated.values))
        jobs = updated
    }
}
