import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Recently Deleted over fake notes, queue, voices and host, in Rome's time zone as Android's tests.
@MainActor struct TrashServiceTests {
    struct Crash: Error {}

    let log = TrashLog()
    let clock: FakeClock
    let notes: FakeTrashNotes
    let queue: FakeTrashQueue
    let voices: FakeVoiceEvidence
    let host = FakeTrashHost()
    let undo = TrashUndo()
    let trash: TrashService
    let calendar: Calendar

    static let rome = TimeZone(identifier: "Europe/Rome")!
    static let day: TimeInterval = 86_400

    /// Rome, local time.
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = rome
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.rome
        self.calendar = calendar
        // Friday 9 Oct 2026, 12:00 in Rome.
        clock = FakeClock(now: Self.at(2026, 10, 9, 12))
        let notes = FakeTrashNotes(log: log)
        let title: (UUID) -> String = { [notes] in notes.note($0)?.title ?? "?" }
        self.notes = notes
        queue = FakeTrashQueue(log: log, title: title)
        voices = FakeVoiceEvidence(log: log, title: title)
        trash = TrashService(.init(notes: notes, queue: queue, voices: voices, host: host, undo: undo, clock: clock,
                                   calendar: calendar))
    }

    @discardableResult
    func note(_ title: String, deleted: Date? = nil, duration: TimeInterval = 0, job: JobState? = nil,
              kind: JobKind = .transcribe) -> UUID {
        var note = Note(title: title, createdAt: clock.now)
        note.duration = duration
        note.trashedAt = deleted
        notes.add(note)
        if let job { queue.jobs[note.id] = TrashedJob(state: job, kind: kind) }
        if job == .running { queue.running.insert(note.id) }
        return note.id
    }

    // MARK: The Library

    // ports: LibraryViewModelTest#trashShowsTheSnackbarAndUndoRestores
    @Test func trashShowsTheSnackbarAndUndoRestores() async throws {
        let id = note("Call with supplier")

        #expect(await trash.requestTrash(id))
        #expect(host.closed == [id], "the note's screen closes: the move lands on the Library")
        #expect(undo.pending == TrashedNote(noteID: id, title: "Call with supplier"))
        undo.showPending(duration: .seconds(12))
        let snackbar = try #require(undo.snackbar)
        #expect(snackbar.note.title == "Call with supplier")
        #expect(snackbar.duration == .seconds(12))
        #expect(undo.pending == nil, "the Library shows it once")

        undo.undo()
        #expect(undo.snackbar == nil)
        #expect(log.events == ["trash Call with supplier", "restore Call with supplier"])
        #expect(notes.note(id)?.trashedAt == nil)
    }

    // ports: LibraryViewModelTest#trashOfARunningNoteAsksFirst
    @Test func trashOfARunningNoteAsksFirst() async throws {
        let id = note("Running", job: .running)

        #expect(await trash.requestTrash(id) == false)
        let confirmation = try #require(trash.stopConfirmation)
        #expect(confirmation == TrashedNote(noteID: id, title: "Running"))
        #expect(log.events.isEmpty)

        trash.cancelStop() // The alert closes before its action runs.
        #expect(await trash.confirmStop(confirmation))
        #expect(trash.stopConfirmation == nil)
        #expect(log.events == ["trash Running"])
        #expect(notes.note(id)?.trashedJob == TrashedJob(state: .paused, kind: .transcribe),
                "the job stopped and kept its progress")
    }

    @Test func cancellingTheStopKeepsTheNoteAndItsJob() async {
        let id = note("Running", job: .running)
        await trash.requestTrash(id)
        trash.cancelStop()
        #expect(trash.stopConfirmation == nil)
        #expect(notes.note(id)?.trashedAt == nil)
        #expect(queue.isRunning(id))
    }

    @Test func aNoteBeingRecordedStaysWhereItIs() async {
        let id = note("Live")
        host.recording.insert(id)
        #expect(await trash.requestTrash(id) == false)
        #expect(notes.note(id)?.trashedAt == nil)
        #expect(undo.pending == nil)
        #expect(log.events.isEmpty)
    }

    @Test func theUndoHandOverIsTakenOnce() {
        let first = TrashedNote(noteID: UUID(), title: "First")
        let second = TrashedNote(noteID: UUID(), title: "Second")
        undo.offer(first)
        undo.offer(second)
        #expect(!undo.take(first), "only the pending note can be taken")
        #expect(undo.take(second))
        #expect(!undo.take(second))
        undo.showPending(duration: .seconds(10))
        #expect(undo.snackbar == nil, "nothing was pending")
    }

    @Test func aSnackbarTimesOutOnlyWhileItIsTheOneShown() async throws {
        let a = note("A"), b = note("B")
        await trash.moveToTrash(a)
        undo.showPending(duration: .seconds(10))
        let first = try #require(undo.snackbar?.id)
        await trash.moveToTrash(b)
        undo.showPending(duration: .seconds(10))
        #expect(undo.snackbar?.note.noteID == b, "a second move replaces the snackbar")
        undo.timedOut(first)
        #expect(undo.snackbar?.note.noteID == b)
        undo.timedOut(try #require(undo.snackbar?.id))
        #expect(undo.snackbar == nil)
        undo.undo()
        #expect(notes.note(b)?.trashedAt != nil, "Undo after the timeout does nothing")
    }

    // MARK: The Trash screen

    // ports: TrashViewModelTest#purgesOnOpenThenShowsTheCardsOldestDeletionFirstWithTheDaysLeft
    @Test func purgesThenShowsTheCardsOldestDeletionFirstWithTheDaysLeft() async throws {
        note("Today's", deleted: Self.at(2026, 10, 9, 1), duration: 5)
        note("Test recording", deleted: Self.at(2026, 10, 2, 18), duration: 60)
        note("Standup", deleted: Self.at(2026, 10, 8, 23))
        note("Live")

        try await trash.purgeExpired()

        #expect(host.purges == [clock.now])
        #expect(trash.items.map(\.title) == ["Test recording", "Standup", "Today's"])
        #expect(trash.items.map(\.daysLeft) == [23, 29, 30])
        #expect(trash.items.map(\.deletedOn) == [.date(Self.at(2026, 10, 2, 0), withYear: false), .yesterday, .today])
    }

    // ports: TrashViewModelTest#restoreGivesTheNoteBack
    @Test func restoreGivesTheNoteBack() {
        let a = note("a", deleted: Self.at(2026, 10, 2, 18))
        let b = note("b", deleted: Self.at(2026, 10, 8, 23))
        #expect(trash.restore(b))
        #expect(trash.items.map(\.id) == [a])
        #expect(!trash.restore(b), "not in Recently Deleted")
    }

    // ports: TrashViewModelTest#emptyAsksWithTheCountAndCancelKeepsEverything (Empty deletes them all)
    @Test func emptyDeletesEveryNote() async throws {
        note("a", deleted: Self.at(2026, 10, 2, 18))
        note("b", deleted: Self.at(2026, 10, 8, 23))
        let live = note("live")
        #expect(try await trash.emptyTrash() == 2)
        #expect(trash.items.isEmpty)
        #expect(notes.notes.map(\.id) == [live])
    }

    // MARK: Jobs (NoteRepositoryTest)

    // ports: NoteRepositoryTest#trashRecordsTheJobAndRestoreRequeuesAQueuedOne
    @Test func trashRecordsTheJobAndRestoreRequeuesAQueuedOne() async {
        let q = note("q", job: .queued)
        let p = note("p", job: .paused, kind: .transcribeAgain)

        #expect(await trash.moveToTrash(q))
        clock.advance(by: .seconds(1))
        #expect(await trash.moveToTrash(p))
        #expect(await trash.moveToTrash(q) == false, "already in Recently Deleted")

        #expect(notes.note(q)?.trashedJob == TrashedJob(state: .queued, kind: .transcribe))
        #expect(notes.note(p)?.trashedJob == TrashedJob(state: .paused, kind: .transcribeAgain))
        #expect(queue.jobs[q] == nil, "a queued job leaves the queue")
        #expect(queue.jobs[p]?.state == .paused, "a paused job stays")
        #expect(trash.items.map(\.id) == [q, p])

        log.clear()
        #expect(trash.restore(q))
        #expect(trash.restore(p))
        #expect(!trash.restore(q), "not in Recently Deleted")

        #expect(log.events == ["restore q", "requeue q transcribe", "restore p"])
        #expect(notes.note(q)?.trashedAt == nil)
        #expect(notes.note(q)?.trashedJob == nil)
        #expect(queue.jobs[p]?.state == .paused, "a paused job was kept")
    }

    // ports: NoteRepositoryTest#purgeExpiredDeletesOnlyNotesWhoseDaysAreOver
    @Test func purgeExpiredDeletesOnlyNotesWhoseDaysAreOver() async throws {
        let old = note("old", deleted: Self.at(2026, 10, 2, 12))
        let recent = note("recent", deleted: Self.at(2026, 10, 9, 12))
        clock.set(Self.at(2026, 11, 1, 10))

        #expect(try await trash.purgeExpired() == 1)

        #expect(notes.note(old) == nil)
        #expect(notes.note(recent) != nil)
        #expect(try await trash.emptyTrash() == 1)
        #expect(notes.notes.isEmpty)
    }

    // MARK: The order of a purge (PurgeOrderTest)

    // ports: PurgeOrderTest#eachStepRunsBeforeTheNext
    @Test func eachStepRunsBeforeTheNext() async throws {
        let purged = note("purged", job: .queued)
        let live = note("live")
        voices.prints = [purged, live]
        await trash.moveToTrash(purged)
        log.clear()
        notes.onDelete = { [voices, notes] id in
            #expect(!voices.prints.contains(id), "the voiceprints go before the files")
            #expect(notes.note(id) != nil)
        }

        #expect(try await trash.deleteNow(purged))

        #expect(log.events == ["job purged", "voices purged", "files purged"])
        #expect(notes.note(purged) == nil)
        #expect(try await trash.deleteNow(live) == false, "a note outside Recently Deleted is not deleted")
        #expect(notes.note(live) != nil)
        #expect(voices.prints == [live], "the other note keeps its voiceprints")
    }

    // ports: PurgeOrderTest#aCrashAfterTheVoiceFilesIsFinishedByTheNextRun
    @Test func aFailureAfterTheVoiceprintsIsFinishedByTheNextRun() async throws {
        let purged = note("purged", deleted: clock.now)
        clock.advance(by: .seconds(31 * Self.day))
        voices.errorAfterRemoving = Crash()

        await #expect(throws: TrashError.deleteFailed(noteID: purged)) { try await trash.purgeExpired() }
        #expect(notes.note(purged)?.trashedAt != nil, "the note is still in Recently Deleted")

        voices.errorAfterRemoving = nil
        #expect(try await trash.purgeExpired() == 1)
        #expect(notes.note(purged) == nil)
    }

    // ports: PurgeOrderTest#aCrashAfterTheFileDeleteIsFinishedByTheNextRun
    @Test func aFailedFileDeleteIsFinishedByTheNextRun() async throws {
        let purged = note("purged", deleted: clock.now)
        let live = note("live")
        clock.advance(by: .seconds(31 * Self.day))
        notes.deleteError = Crash()

        await #expect(throws: TrashError.deleteFailed(noteID: purged)) { try await trash.purgeExpired() }
        #expect(notes.note(purged)?.trashedAt != nil)

        notes.deleteError = nil
        #expect(try await trash.purgeExpired() == 1)
        #expect(notes.note(purged) == nil)
        #expect(notes.note(live) != nil)
        #expect(try await trash.purgeExpired() == 0)
    }

    // ports: PurgeOrderTest#aRestoreAfterTheTrashSnapshotKeepsTheNote
    @Test func aRestoreAfterEmptyStartedKeepsTheNote() async throws {
        let purged = note("purged", deleted: clock.now)
        let live = note("live", deleted: clock.now.addingTimeInterval(1))
        var restored = false
        queue.onCancel = { [trash] id in if id == purged { restored = trash.restore(live) } }

        #expect(try await trash.emptyTrash() == 1)

        #expect(restored)
        #expect(notes.note(live)?.trashedAt == nil)
        #expect(notes.note(purged) == nil)
    }

    // ports: PurgeOrderTest#anExpiredNoteRestoredAndTrashedAgainIsNotPurged
    @Test func anExpiredNoteRestoredAndTrashedAgainIsNotPurged() async throws {
        let purged = note("purged", deleted: clock.now)
        let live = note("live", deleted: clock.now.addingTimeInterval(1)) // Purged second, oldest deletion first.
        clock.advance(by: .seconds(31 * Self.day))
        // After the expired notes were listed, the second goes back to the Library and to Recently Deleted again: its
        // 30 days start again.
        queue.onCancel = { [trash] id in
            guard id == purged else { return }
            #expect(trash.restore(live))
            #expect(await trash.moveToTrash(live))
        }

        #expect(try await trash.purgeExpired() == 1)

        #expect(notes.note(live)?.trashedAt == clock.now)
    }

    // ports: PurgeOrderTest#aRestoreDuringThePurgeOfTheSameNoteIsRefused
    @Test func aRestoreDuringTheDeleteOfTheSameNoteIsRefused() async throws {
        let purged = note("purged", deleted: clock.now)
        var restored: Bool?
        queue.onCancel = { [trash] id in if id == purged { restored = trash.restore(purged) } }

        #expect(try await trash.deleteNow(purged))

        #expect(restored == false, "a note being deleted cannot come back")
        #expect(notes.note(purged) == nil)
    }

    // ports: PurgeOrderTest#aRestoreAfterAFailedPurgeBringsTheDocumentBackWithoutItsVoices
    @Test func aRestoreAfterAFailedDeleteBringsTheNoteBackWithoutItsVoiceprints() async throws {
        let purged = note("purged", deleted: clock.now)
        voices.prints = [purged]
        voices.errorAfterRemoving = Crash()
        await #expect(throws: TrashError.deleteFailed(noteID: purged)) { try await trash.deleteNow(purged) }

        #expect(trash.restore(purged), "the failed delete gave the note back")
        #expect(notes.note(purged)?.trashedAt == nil)
        #expect(!voices.prints.contains(purged), "the delete removed its voiceprints")
    }

    // MARK: Saved voices unavailable

    @Test func unreadableVoicesDeleteNothingAndSayItOnce() async throws {
        let expired = note("expired", deleted: clock.now)
        clock.advance(by: .seconds(31 * Self.day))
        voices.isReadable = false

        await #expect(throws: TrashError.voicesUnavailable) { try await trash.purgeExpired() }
        await #expect(throws: TrashError.voicesUnavailable) { try await trash.deleteNow(expired) }
        await #expect(throws: TrashError.voicesUnavailable) { try await trash.emptyTrash() }

        #expect(trash.voicesUnavailable)
        var facts = NoticeFacts()
        trash.contribute(to: &facts)
        #expect(facts.voicesUnavailable, "one lasting fact for the notices")
        #expect(notes.note(expired) != nil, "nothing is deleted")
        #expect(log.events.isEmpty, "not even its job")
        #expect(host.purges.isEmpty)

        voices.isReadable = true
        #expect(try await trash.purgeExpired() == 1)
        #expect(!trash.voicesUnavailable)
    }
}
