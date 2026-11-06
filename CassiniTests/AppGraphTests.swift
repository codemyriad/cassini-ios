import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

@MainActor final class AppGraphTests: XCTestCase {
    // ports: AppGraphTest#theGraphBuildsOnAScratchRootAndReadyCompletes
    func testTheGraphBuildsOnAScratchRootAndReadyCompletes() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let standardQueueHold = UserDefaults.standard.string(forKey: SettingsKeys.queueHold)
        let report = await test.graph.start()
        XCTAssertTrue(test.graph.startup.isReady)
        XCTAssertEqual(report.ran, StartupStep.allCases)
        XCTAssertEqual(report.failed, [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: test.root.path), "the library is under the scratch root")
        XCTAssertNil(test.graph.library.loadFailure)
        test.graph.settings.queueHold = .user
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.queueHold), standardQueueHold, "preferences never leak into the standard suite")
    }

    func testBackgroundExpiryPausesTheJobHoldsTheQueueAndEndsTheTaskBeforeReturning() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 5, total: 10)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let outcome = await graph.processing.transcribe(note.id)
        XCTAssertEqual(outcome, .queued(changed: true))
        await waitUntil { graph.processing.progress.fraction(for: note.id) == 0.5 }
        XCTAssertEqual(graph.processing.state.running?.fraction, 0.5)
        XCTAssertEqual(test.background.activeCount, 1)

        test.background.expireAll()

        XCTAssertEqual(test.background.activeCount, 0)
        XCTAssertEqual(test.background.endedCount, 1)
        XCTAssertEqual(graph.settings.queueHold, .system, "the queue waits for Continue or Resume")
        await waitUntil { graph.processing.state.running == nil }
        let job = try XCTUnwrap(graph.processing.state.jobs[note.id])
        XCTAssertEqual(job.state, .paused)
        XCTAssertEqual(job.pauseReason, .system)
        await graph.library.settle()
        XCTAssertEqual(graph.library.note(note.id)?.status, .audioOnly)
        XCTAssertEqual(test.background.endedCount, 1, "the stopped job does not end its task twice")
        let stored = try JobRepository(root: test.root).load()
        XCTAssertEqual(stored.map(\.state), [.paused], "the paused job survives a relaunch")
    }

    func testTakingQueuedNotesOutOfTheQueueKeepsTheirSavedProgressAndStartOverDropsIt() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 5, total: 10)))
        defer { test.tearDown() }
        let seeded = try await seedPlainNotes(2, in: test)
        let running = seeded[0], paused = seeded[1]
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        try checkpoints.save(checkpoint(of: paused, in: test, language: graph.settings.speechLanguage), for: paused.id)
        await graph.processing.transcribe(running.id)
        await graph.processing.transcribe(paused.id)
        XCTAssertTrue(graph.processing.state.isQueued(paused.id))

        // Remove from queue keeps it: the job is paused by the user.
        let removed = await graph.processing.coordinator?.dequeue(paused.id)
        XCTAssertEqual(removed, .paused)
        XCTAssertFalse(graph.processing.state.isQueued(paused.id))
        XCTAssertTrue(checkpoints.exists(paused.id))
        XCTAssertTrue(graph.processing.hasSavedProgress(paused.id))

        // So does iOS taking the background time back: the queue is held and the queued note waits with it.
        await graph.processing.transcribe(paused.id)
        test.background.expireAll()
        XCTAssertEqual(graph.settings.queueHold, .system)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertTrue(graph.processing.state.isQueued(paused.id))
        XCTAssertTrue(checkpoints.exists(paused.id), "a queued note keeps its saved progress when iOS ends the background time")

        // Start over drops it.
        await graph.processing.coordinator?.startOver(paused.id)
        XCTAssertFalse(checkpoints.exists(paused.id))
        XCTAssertTrue(graph.processing.state.isQueued(paused.id), "queued again behind the hold")
    }

    // ports: ProcessingCoordinatorTest#trashDeletesAQueuedRowButKeepsItsWork
    func testTrashingAQueuedNoteKeepsItsSavedProgress() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1, total: 2)))
        defer { test.tearDown() }
        let seeded = try await seedPlainNotes(2, in: test)
        let running = seeded[0], queued = seeded[1]
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        try checkpoints.save(pausedCheckpoint(of: queued, in: test, language: graph.settings.speechLanguage), for: queued.id)
        await graph.processing.transcribe(running.id)
        await graph.processing.transcribe(queued.id)

        let moved = await graph.trash.moveToTrash(queued.id)
        XCTAssertTrue(moved)
        XCTAssertFalse(graph.processing.state.isQueued(queued.id))
        XCTAssertTrue(checkpoints.exists(queued.id), "Restore needs the checkpoint")
        XCTAssertTrue(graph.processing.state.isRunning(running.id), "the running note is untouched")

        graph.trash.restore(queued.id)
        XCTAssertTrue(graph.processing.hasSavedProgress(queued.id))
        XCTAssertEqual(try checkpoints.load(queued.id)?.doneMs, 1_000)
        await waitUntil { graph.processing.state.isQueued(queued.id) }
        XCTAssertEqual(graph.processing.state.jobs[queued.id]?.doneMs, 1_000, "queued again with its saved progress")
    }

    // ports: ProcessingCoordinatorTest#trashStopsARunningJobAndKeepsItsProgress
    func testTrashingARunningNoteKeepsItsProgressAndARestoredNoteResumes() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1.5, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        try checkpoints.save(pausedCheckpoint(of: note, in: test, language: graph.settings.speechLanguage), for: note.id)
        await graph.processing.transcribe(note.id)
        await waitUntil { graph.processing.progress.fraction(for: note.id) ?? 0 > 0 }

        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        XCTAssertNil(graph.processing.state.running, "the note moves once its job has ended")
        XCTAssertTrue(checkpoints.exists(note.id))
        XCTAssertEqual(try checkpoints.load(note.id)?.doneMs, 1_000)
        XCTAssertNil(graph.library.note(note.id)?.failure)
        XCTAssertNotNil(graph.library.note(note.id)?.trashedAt)
        XCTAssertFalse(graph.notices.library(LibraryFacts(loading: true)).contains { $0.kind.group == .transcription },
                       "a trashed note says nothing about its pause")

        graph.trash.restore(note.id)
        XCTAssertTrue(graph.processing.hasSavedProgress(note.id))
        await graph.processing.transcribe(note.id)
        await waitUntil { draftText(graph.processing.progress.phase(for: note.id)) == ["Hello"] }
        XCTAssertEqual(draftText(graph.processing.progress.phase(for: note.id)), ["Hello"],
                       "the run resumed from the saved progress")
        graph.processing.stop(note.id)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertEqual(try checkpoints.load(note.id)?.doneMs, 1_000)
    }

    func testDeletingARunningNoteForGoodRightAfterTrashingItLeavesNoFolder() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1.5, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let folder = try XCTUnwrap(graph.library.directory(for: note.id))
        await graph.processing.transcribe(note.id)
        await waitUntil { graph.processing.progress.fraction(for: note.id) ?? 0 > 0 }

        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        try await graph.trash.deleteNow(note.id)
        await graph.library.settle()
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertNil(graph.library.note(note.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "no late checkpoint brings the folder back")
        XCTAssertNil(graph.errors.current)
    }

    func testARestoredNoteCanBeTranscribedRightAway() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1.5, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        await graph.processing.transcribe(note.id)
        await waitUntil { graph.processing.progress.fraction(for: note.id) ?? 0 > 0 }

        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        graph.trash.restore(note.id)
        let outcome = await graph.processing.transcribe(note.id)
        XCTAssertEqual(outcome, .queued(changed: true), "Transcribe right after Restore queues the note")
        graph.processing.stop(note.id)
        await waitUntil { graph.processing.state.running == nil }
    }

    /// Android's `TX_CHECKPOINT_MISMATCH` banner offers Start over: saved progress that no longer matches stays until
    /// then, and Start over transcribes the note from the beginning.
    func testAMismatchFailsTheJobAndStartOverTranscribesFromTheBeginning() async throws {
        let words = [TranscriptSegment(text: "Hello there.", start: 0, end: 1.5)]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        var stale = checkpoint(of: note, in: test, language: graph.settings.speechLanguage)
        stale.signature = "1:2"
        try checkpoints.save(stale, for: note.id)

        await graph.processing.transcribe(note.id)
        await graph.processing.coordinator?.awaitIdle()
        await waitUntil { graph.library.note(note.id)?.failure == .checkpointMismatch }
        XCTAssertEqual(graph.processing.state.jobs[note.id]?.state, .failed)

        await graph.processing.coordinator?.startOver(note.id)
        await graph.processing.coordinator?.awaitIdle()
        await waitUntil { graph.library.note(note.id)?.status == .ready }
        XCTAssertEqual(graph.library.note(note.id)?.text, "Hello there.")
        XCTAssertFalse(checkpoints.exists(note.id))
    }

    func testAPausedNoteResumesInTheLanguageItBeganIn() async throws {
        let words = [TranscriptSegment(text: "Hello", start: 0, end: 0.8, words: [.init(text: "Hello", start: 0, end: 0.8)]),
                     TranscriptSegment(text: "to everyone", start: 1, end: 1.8, words: [.init(text: "to", start: 1, end: 1.2),
                                                                                    .init(text: " everyone", start: 1.3, end: 1.8)])]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        await graph.library.settle()
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        var paused = checkpoint(of: note, in: test, language: "it-IT")
        paused.segments = [words[0]]
        paused.doneMs = 900
        try checkpoints.save(paused, for: note.id)
        graph.settings.speechLanguage = "en-US"

        await graph.processing.transcribe(note.id)
        await graph.processing.coordinator?.awaitIdle()
        await waitUntil { graph.library.note(note.id)?.status == .ready }
        XCTAssertEqual(graph.library.note(note.id)?.language, "it-IT", "the run's language, from its checkpoint (D53.2)")
        XCTAssertEqual(graph.library.note(note.id)?.transcript.map(\.text), ["Hello", "to everyone"])
        XCTAssertFalse(checkpoints.exists(note.id))
    }

    func testAStopBeforeAnyWordsSaysSo() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 0, total: 10)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        await graph.processing.transcribe(note.id)
        await waitUntil { graph.processing.progress.phase(for: note.id).map { if case .transcribing = $0 { true } else { false } } == true }
        graph.processing.stop(note.id)
        await graph.processing.coordinator?.awaitIdle()
        await waitUntil { graph.library.note(note.id)?.status == .audioOnly }
        XCTAssertNil(graph.library.note(note.id)?.failure)
        let banners = Notices.job(graph.processing.state.jobs[note.id])
        XCTAssertEqual(banners.map(\.kind), [.txPausedEarly], "the Note screen says it stopped before any words")
        XCTAssertEqual(banners.first.map(BannerCopy.title), "Paused before any words were found")
        XCTAssertEqual(banners.first.flatMap { BannerCopy.body($0) }, "Resume to start transcribing.")
        XCTAssertEqual(banners.first?.actions, [.resume])
    }

    func testAFinishedJobSavesTheTranscriptAndEndsItsBackgroundTask() async throws {
        let words = [TranscriptSegment(text: "Hello there.", start: 0, end: 1)]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        await graph.processing.transcribe(note.id)
        await graph.processing.coordinator?.awaitIdle()
        await graph.library.settle()
        await waitUntil { graph.library.note(note.id)?.status == .ready }
        XCTAssertEqual(graph.library.note(note.id)?.text, "Hello there.")
        XCTAssertEqual(test.background.endedCount, 1)
        XCTAssertTrue(graph.processing.state.jobs.isEmpty)
        let stored = try NoteRepository(root: test.root).load().notes.first { $0.id == note.id }
        XCTAssertEqual(stored?.transcript.map(\.text), ["Hello there."])
        XCTAssertEqual(stored?.status, .ready)
    }

    func testWithoutConsentTranscribeOpensNothingAndWaitsAsReadyToTranscribe() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.returns([], total: 1), status: .notDownloaded))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let outcome = await test.graph.processing.transcribe(note.id)
        XCTAssertEqual(outcome, .needsConsent)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.state, .needsConsent)
        XCTAssertNil(test.graph.processing.state.running)
    }

    // ports: ProcessingCoordinatorTest#aQueuedJobWithoutConsentEndsNeedsConsentInTheRealJob
    func testAQueuedJobWithoutConsentEndsNeedsConsentInTheRealJob() async throws {
        // A queue from before the model was removed: the job is queued, there is no consent and nothing installed.
        let test = TestGraph(transcriber: FakeTranscriber(.returns([], total: 1), status: .notDownloaded))
        defer { test.tearDown() }
        var note = Note(title: "Waiting", audioFilename: "audio.caf")
        note.duration = 2
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        try JobRepository(root: test.root).save([Job(noteID: note.id, seq: 1, kind: .transcribe, enqueuedAt: test.clock.now)])
        await test.graph.start()
        let coordinator = try XCTUnwrap(test.graph.processing.coordinator)

        coordinator.drain()
        await waitUntil { coordinator.isDraining }
        await coordinator.awaitIdle()
        XCTAssertEqual(try JobRepository(root: test.root).load().map(\.state), [.needsConsent])
        XCTAssertEqual(test.notifier.posted.map(\.noteID), [note.id])
        XCTAssertEqual(test.notifier.posted.first?.kind, .readyToTranscribe)
    }

    func testOneErrorIsShownAtATimeInOrder() {
        let errors = ErrorPresenter()
        errors.present("First")
        errors.present("Second")
        errors.present("First")
        XCTAssertEqual(errors.current?.message, "First")
        errors.dismiss(UUID())
        XCTAssertEqual(errors.current?.message, "First", "dismissing another alert keeps this one")
        errors.dismiss(errors.current!.id)
        XCTAssertEqual(errors.current?.message, "Second")
        errors.dismiss(errors.current!.id)
        XCTAssertNil(errors.current)
    }

    func testAnEditToAValueMadeInAnEarlierQueuedEditIsWritten() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let library = test.graph.library
        library.updateAll { $0.isFavorite = true }
        let added = UUID()
        library.update(note.id) { $0.addBookmark(at: 1, id: added) }
        let bookmark = try XCTUnwrap(library.note(note.id)?.bookmarks.first)
        library.update(note.id) { $0.bookmarks.removeAll { $0.id == bookmark.id } }
        await library.settle()

        XCTAssertEqual(library.note(note.id)?.bookmarks, [])
        let stored = try NoteRepository(root: test.root).load().notes.first { $0.id == note.id }
        XCTAssertEqual(stored?.bookmarks, [])
        XCTAssertEqual(stored?.isFavorite, true)
        XCTAssertNil(test.graph.errors.current)
    }

    func testAWriteMadeStraightToTheStoreWhileEditsAreQueuedKeepsEveryChange() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let library = test.graph.library
        let noteStore = try XCTUnwrap(library.noteStore)
        let bookmark = UUID()
        library.update(note.id) { $0.isFavorite = true }
        library.update(note.id) { $0.addBookmark(at: 1, id: bookmark) }
        // An engine writer (a transcription job, say) saves the note before the queued edits reach the store.
        try await noteStore.mutate(note.id) {
            $0.transcript = [TranscriptSegment(text: "Hello there.", start: 0, end: 1)]
            $0.status = .ready
        }
        library.update(note.id) { $0.playbackPosition = 1.5 }
        await library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.isFavorite, true)
        XCTAssertEqual(stored.bookmarks.map(\.id), [bookmark])
        XCTAssertEqual(stored.text, "Hello there.")
        XCTAssertEqual(stored.status, .ready)
        XCTAssertEqual(stored.playbackPosition, 1.5)
        XCTAssertEqual(library.note(note.id), stored, "the screens show the note as stored")
        XCTAssertNil(test.graph.errors.current)
    }

    func testTrashingANoteOpenInTheDetailColumnClosesIt() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.router.isSplit = true
        graph.router.show(.note(note.id))
        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        XCTAssertEqual(graph.router.path, [])
    }

    func testGoingToTheBackgroundHoldsATaskUntilThePositionIsSaved() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.playback.show(try XCTUnwrap(graph.library.note(note.id)), owner: PlaybackOwner())
        graph.playback.seek(1.5)

        graph.enterBackground()
        XCTAssertEqual(test.background.activeCount, 1)
        await waitUntil { test.background.activeCount == 0 }

        let stored = try NoteRepository(root: test.root).load().notes.first { $0.id == note.id }
        XCTAssertEqual(stored?.playbackPosition, 1.5)
    }

    private func seedPlainNote(in test: TestGraph) async throws -> Note {
        try await seedPlainNotes(1, in: test)[0]
    }

    /// Two-second notes with an audio file each, then the launch that loads them.
    private func seedPlainNotes(_ count: Int, in test: TestGraph) async throws -> [Note] {
        let repository = try NoteRepository(root: test.root)
        var notes: [Note] = []
        for _ in 0..<count {
            var note = Note(title: "Plain", audioFilename: "audio.caf")
            note.duration = 2
            try repository.save(note)
            try Data().write(to: audioURL(note, in: test))
            notes.append(note)
        }
        await test.graph.start()
        return notes
    }

    private func audioURL(_ note: Note, in test: TestGraph) -> URL {
        test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf")
    }

    /// A checkpoint of `note`'s audio, as a paused job leaves it.
    private func checkpoint(of note: Note, in test: TestGraph, language: String) -> CheckpointState {
        CheckpointState(source: "audio.caf", signature: CheckpointState.signature(of: audioURL(note, in: test)),
                        model: CheckpointState.appleModel(language: language), segments: [], doneMs: 0, totalMs: 2_000, elapsedMs: 1_000)
    }

    /// A checkpoint that holds the first second of `note`'s words.
    private func pausedCheckpoint(of note: Note, in test: TestGraph, language: String) -> CheckpointState {
        var paused = checkpoint(of: note, in: test, language: language)
        paused.segments = [TranscriptSegment(text: "Hello", start: 0, end: 0.8,
                                             words: [.init(text: "Hello", start: 0, end: 0.8)])]
        paused.doneMs = 1_000
        return paused
    }

    private func draftText(_ phase: JobPhase?) -> [String]? {
        guard case .transcribing(_, let draft) = phase else { return nil }
        return draft.words.map(\.text)
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
