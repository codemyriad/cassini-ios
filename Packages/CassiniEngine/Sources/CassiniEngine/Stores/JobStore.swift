import Foundation
import CassiniNotebook

/// The durable transcription queue: at most one job per note, first in first out by `seq`, at most one running.
/// Every change is written before it returns.
public actor JobStore {
    private let repository: JobRepository
    private var jobs: [UUID: Job] = [:]

    public init(repository: JobRepository) {
        self.repository = repository
    }

    /// Reads the queue from disk, replacing what is in memory.
    @discardableResult public func load() throws -> [Job] {
        let stored = try repository.load()
        jobs = Dictionary(stored.map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        return all()
    }

    /// In `seq` order.
    public func all() -> [Job] { jobs.values.sorted { $0.seq < $1.seq } }

    public func job(_ noteID: UUID) -> Job? { jobs[noteID] }

    /// Puts the note's job at the back of the queue. A queued or running job is left as it is; any other job starts
    /// afresh, with no failure, pause reason, attempts or progress.
    @discardableResult
    public func enqueue(_ noteID: UUID, kind: JobKind, language: String, now: Date) throws -> Job {
        if let existing = jobs[noteID], existing.state == .queued || existing.state == .running { return existing }
        let job = Job(noteID: noteID, seq: nextSeq, kind: kind, language: language, enqueuedAt: now)
        try write(job)
        return job
    }

    /// Marks the first queued job running, unless a job runs already or there is none.
    public func claimNext(now: Date, skipping skipped: Set<UUID> = []) throws -> Job? {
        guard !jobs.values.contains(where: { $0.state == .running }),
              var job = all().first(where: { $0.state == .queued && !skipped.contains($0.noteID) }) else { return nil }
        job.state = .running
        job.updatedAt = now
        try write(job)
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
        try write(job)
        return job
    }

    public func remove(_ noteID: UUID) throws {
        guard let removed = jobs.removeValue(forKey: noteID) else { return }
        do { try repository.save(all()) } catch {
            jobs[noteID] = removed
            throw error
        }
    }

    private var nextSeq: Int { (jobs.values.map(\.seq).max() ?? 0) + 1 }

    private func write(_ job: Job) throws {
        var updated = jobs
        updated[job.noteID] = job
        try repository.save(Array(updated.values))
        jobs = updated
    }
}
