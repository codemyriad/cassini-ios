import Foundation
import CassiniNotebook

/// The queue's writes and the note statuses that follow them; every one runs inside the serial section.
///
/// Touches: `parts.jobs`, `parts.notes` and `parts.checkpoints` (writes), `trashed` (an enqueue takes the note out),
/// `refresh()`.
extension TranscriptionCoordinator {
    /// The language a job is queued with: the Settings language for the transcribe kinds, except that saved progress
    /// resumes in the language it began in (its job's, else its checkpoint's), which the checkpoint must match. Nil for
    /// a speakers-only job, which decodes nothing and keeps its job's. The note's language is never read or set here:
    /// it is the language of the words it shows, which only a finished run changes (`TranscriptLanguage`).
    func language(for noteID: UUID, kind: JobKind) async -> String? {
        guard let spoken = EnqueueRules.language(for: kind, speechLanguage: settings.speechLanguage) else { return nil }
        if case .saved = await parts.checkpoints.status(of: noteID) {
            let job = await parts.jobs.job(noteID)?.language ?? ""
            let began = job.isEmpty ? await parts.checkpoints.language(of: noteID) : job
            if let began, !began.isEmpty { return began }
        }
        return spoken
    }

    func enqueue(_ noteID: UUID, kind: JobKind, language: String?) async -> TranscribeOutcome {
        let existing = await parts.jobs.job(noteID)
        if let existing, existing.state == .queued || existing.state == .running { return .queued(changed: false) }
        guard await write({ try await $0.enqueue(noteID, kind: kind, language: language, now: self.parts.clock.now) }) != nil else {
            return .queued(changed: false)
        }
        trashed.remove(noteID)
        await mirror(noteID)
        await refresh()
        return .queued(changed: true)
    }

    func needConsent(_ noteID: UUID, kind: JobKind, language: String?) async -> TranscribeOutcome {
        let now = parts.clock.now
        switch await parts.jobs.job(noteID)?.state {
        case .running:
            return .queued(changed: false)
        case .queued:
            await write { try await $0.transition(noteID, now: now) { $0.state = .needsConsent } }
        default:
            await write { try await $0.enqueue(noteID, kind: kind, language: language, now: now, waitingForConsent: true) }
        }
        await mirror(noteID)
        await refresh()
        return .needsConsent
    }

    /// Paused for `reason` with the numbers of the saved progress (none without it).
    func markPaused(_ noteID: UUID, _ reason: PauseReason) async {
        let checkpoint = await parts.checkpoints.status(of: noteID)
        await write {
            try await $0.transition(noteID, now: self.parts.clock.now) { job in
                let total = job.totalMs
                job = job.withNumbers(of: checkpoint)
                if case .saved = checkpoint {} else { job.totalMs = total }
                job.state = .paused
                job.pauseReason = reason
                job.failure = nil
            }
        }
    }

    func markFailed(_ noteID: UUID, _ failure: JobFailure) async {
        await write {
            try await $0.transition(noteID, now: self.parts.clock.now) { $0.state = .failed; $0.failure = failure; $0.pauseReason = nil }
        }
    }

    /// Start over and a trashed note's end: the `work/` directory, then the job.
    func discardWork(_ noteID: UUID) async {
        do { try await parts.checkpoints.discard(noteID) } catch { log.error("Cannot discard the work of \(noteID): \(String(describing: error))") }
        await write { try await $0.remove(noteID) }
    }

    /// Brings the note's stored status in line with its job. `closedDuringJob` marks a note that says it was transcribing although no job remains (an older version's queue).
    func mirror(_ noteID: UUID, _ known: Job?? = nil, clearingFailure: Bool = false,
                        closedDuringJob: Bool = false) async {
        let job: Job? = if let known { known } else { await parts.jobs.job(noteID) }
        do {
            try await parts.notes.mutate(noteID) { note in
                let wasWorking = note.status == .queued || note.status == .transcribing
                note.status = .mirroring(job, hasTranscript: !note.transcript.isEmpty)
                switch job?.state {
                case .failed: note.failure = job?.failure
                case .queued, .running: note.failure = nil
                case .paused, .needsConsent, nil: if clearingFailure { note.failure = nil }
                }
                if closedDuringJob, wasWorking { note.failure = .interrupted }
            }
        } catch {
            log.error("Cannot save the status of \(noteID): \(String(describing: error))")
        }
    }

    /// Runs a queue write; a failed one is logged and leaves the queue as it was. Returns the result, nil on failure.
    @discardableResult
    func write<T>(_ body: (JobStore) async throws -> T) async -> T? {
        do { return try await body(parts.jobs) } catch {
            log.error("Cannot write the queue: \(String(describing: error))")
            return nil
        }
    }
}
