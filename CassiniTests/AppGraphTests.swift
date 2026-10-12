import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

@MainActor final class AppGraphTests: XCTestCase {
    // ports: AppGraphTest#theGraphBuildsOnAScratchRootAndReadyCompletes
    func testTheGraphBuildsOnAScratchRootAndReadyCompletes() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let standardIdentity = UserDefaults.standard.string(forKey: SettingsKeys.speakerModelIdentity)
        let report = await test.graph.start()
        XCTAssertTrue(test.graph.startup.isReady)
        XCTAssertEqual(report.ran, StartupStep.allCases)
        XCTAssertEqual(report.failed, [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: test.root.path), "the library is under the scratch root")
        XCTAssertNil(test.graph.library.loadFailure)
        test.graph.settings.speakerModelIdentity = "scratch-model"
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.speakerModelIdentity), standardIdentity, "preferences never leak into the standard suite")
    }

    func testBackgroundExpiryStopsTheJobAndEndsTheTaskBeforeReturning() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 5, total: 10)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        graph.processing.enqueue(note.id)
        XCTAssertTrue(graph.processing.state.isRunning(note.id))
        XCTAssertEqual(test.background.activeCount, 1)
        await waitUntil { graph.processing.progress.fraction(for: note.id) == 0.5 }

        test.background.expireAll()

        XCTAssertEqual(test.background.activeCount, 0)
        XCTAssertEqual(test.background.endedCount, 1)
        XCTAssertEqual(graph.library.note(note.id)?.status, .audioOnly)
        XCTAssertEqual(graph.library.note(note.id)?.failure, .interrupted)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertEqual(test.background.endedCount, 1, "the finished job does not end its task twice")
    }

    func testTakingQueuedNotesOutOfTheQueueKeepsTheirSavedProgress() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 5, total: 10)))
        defer { test.tearDown() }
        let seeded = try await seedPlainNotes(2, in: test)
        let running = seeded[0], paused = seeded[1]
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        try checkpoints.save(checkpoint(of: paused, in: test, language: graph.settings.speechLanguage), for: paused.id)
        graph.processing.enqueue(running.id)
        graph.processing.enqueue(paused.id)
        XCTAssertTrue(graph.processing.state.isQueued(paused.id))

        // Remove from queue keeps it.
        graph.processing.dequeue(paused.id)
        XCTAssertFalse(graph.processing.state.isQueued(paused.id))
        XCTAssertTrue(checkpoints.exists(paused.id))
        XCTAssertTrue(graph.processing.hasSavedProgress(paused.id))

        // So does iOS taking the background time back.
        graph.processing.enqueue(paused.id)
        test.background.expireAll()
        XCTAssertFalse(graph.processing.state.isQueued(paused.id))
        XCTAssertEqual(graph.library.note(paused.id)?.failure, .interrupted)
        XCTAssertTrue(checkpoints.exists(paused.id), "a queued note keeps its saved progress when iOS ends the background time")
        await waitUntil { graph.processing.state.running == nil }

        // Cancel drops it.
        graph.processing.enqueue(running.id)
        graph.processing.enqueue(paused.id)
        graph.processing.cancel(paused.id)
        XCTAssertFalse(checkpoints.exists(paused.id))
    }

    // ports: ProcessingCoordinatorTest#trashDeletesAQueuedRowButKeepsItsWork
    func testTrashingAQueuedNoteKeepsItsSavedProgress() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1, total: 2)))
        defer { test.tearDown() }
        let seeded = try await seedPlainNotes(2, in: test)
        let running = seeded[0], queued = seeded[1]
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        try checkpoints.save(pausedCheckpoint(of: queued, in: test, language: graph.settings.speechLanguage), for: queued.id)
        graph.processing.enqueue(running.id)
        graph.processing.enqueue(queued.id)

        let moved = await graph.trash.moveToTrash(queued.id)
        XCTAssertTrue(moved)
        XCTAssertFalse(graph.processing.state.isQueued(queued.id))
        XCTAssertTrue(checkpoints.exists(queued.id), "Restore needs the checkpoint")
        XCTAssertTrue(graph.processing.state.isRunning(running.id), "the running note is untouched")

        graph.trash.restore(queued.id)
        XCTAssertTrue(graph.processing.hasSavedProgress(queued.id))
        XCTAssertEqual(try checkpoints.load(queued.id)?.doneMs, 1_000)
    }

    // ports: ProcessingCoordinatorTest#trashStopsARunningJobAndKeepsItsProgress
    func testTrashingARunningNoteKeepsItsProgressAndARestoredNoteResumes() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1.5, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        try checkpoints.save(pausedCheckpoint(of: note, in: test, language: graph.settings.speechLanguage), for: note.id)
        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.progress.fraction(for: note.id) ?? 0 > 0 }

        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        XCTAssertNil(graph.processing.state.running, "the note moves once its job has ended")
        XCTAssertTrue(checkpoints.exists(note.id))
        XCTAssertEqual(try checkpoints.load(note.id)?.doneMs, 1_000)
        XCTAssertNil(graph.library.note(note.id)?.failure)
        XCTAssertNotNil(graph.library.note(note.id)?.trashedAt)
        XCTAssertEqual(graph.notices.notices.map(\.text), [], "a trashed note says nothing about its pause")

        graph.trash.restore(note.id)
        XCTAssertTrue(graph.processing.hasSavedProgress(note.id))
        graph.processing.enqueue(note.id)
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
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        let folder = try XCTUnwrap(graph.library.directory(for: note.id))
        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.progress.fraction(for: note.id) ?? 0 > 0 }

        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        await graph.trash.deletePermanently(note.id)
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
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.progress.fraction(for: note.id) ?? 0 > 0 }

        let moved = await graph.trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        graph.trash.restore(note.id)
        graph.processing.enqueue(note.id)
        XCTAssertTrue(graph.processing.state.isRunning(note.id) || graph.processing.state.isQueued(note.id),
                      "Transcribe right after Restore queues the note")
        graph.processing.stop(note.id)
        await waitUntil { graph.processing.state.running == nil }
    }

    func testARetryAfterAMismatchStartsOver() async throws {
        let words = [TranscriptSegment(text: "Hello there.", start: 0, end: 1.5)]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        var stale = checkpoint(of: note, in: test, language: graph.settings.speechLanguage)
        stale.signature = "1:2"
        try checkpoints.save(stale, for: note.id)

        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertEqual(graph.library.note(note.id)?.failure, .checkpointMismatch)
        XCTAssertFalse(checkpoints.exists(note.id), "no new try can use it")

        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertEqual(graph.library.note(note.id)?.status, .ready)
        XCTAssertEqual(graph.library.note(note.id)?.text, "Hello there.")
    }

    func testAPausedNoteResumesInTheLanguageItBeganIn() async throws {
        let words = [TranscriptSegment(text: "Ciao", start: 0, end: 0.8, words: [.init(text: "Ciao", start: 0, end: 0.8)]),
                     TranscriptSegment(text: "a tutti", start: 1, end: 1.8, words: [.init(text: "a", start: 1, end: 1.2),
                                                                                    .init(text: " tutti", start: 1.3, end: 1.8)])]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        graph.library.update(note.id) { $0.language = "it-IT" }
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(graph.library.noteStore))
        var paused = checkpoint(of: note, in: test, language: "it-IT")
        paused.segments = [words[0]]
        paused.doneMs = 900
        try checkpoints.save(paused, for: note.id)
        graph.settings.speechLanguage = "en-US"

        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertEqual(graph.library.note(note.id)?.status, .ready)
        XCTAssertEqual(graph.library.note(note.id)?.language, "it-IT")
        XCTAssertEqual(graph.library.note(note.id)?.transcript.map(\.text), ["Ciao", "a tutti"])
        XCTAssertFalse(checkpoints.exists(note.id))
    }

    func testAStopBeforeAnyWordsSaysSo() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 0, total: 10)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.progress.phase(for: note.id).map { if case .transcribing = $0 { true } else { false } } == true }
        graph.processing.stop(note.id)
        await waitUntil { graph.processing.state.running == nil }
        XCTAssertEqual(graph.library.note(note.id)?.status, .audioOnly)
        XCTAssertNil(graph.library.note(note.id)?.failure)
        XCTAssertEqual(graph.notices.notices.map(\.text), ["Paused before any words were found. Resume to start transcribing."])
    }

    func testAFinishedJobSavesTheTranscriptAndEndsItsBackgroundTask() async throws {
        let words = [TranscriptSegment(text: "Hello there.", start: 0, end: 1)]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        graph.processing.enqueue(note.id)
        await waitUntil { graph.processing.state.running == nil }
        await graph.library.settle()
        XCTAssertEqual(graph.library.note(note.id)?.status, .ready)
        XCTAssertEqual(graph.library.note(note.id)?.text, "Hello there.")
        XCTAssertEqual(test.background.endedCount, 1)
        let stored = try NoteRepository(root: test.root).load().notes.first { $0.id == note.id }
        XCTAssertEqual(stored?.transcript.map(\.text), ["Hello there."])
    }

    func testVoiceNamingPersistenceForgetAndTrashExpiry() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Speaker session")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"), .init(text: "Again", start: 9, end: 12, speaker: "Speaker 1", speakerID: "a")]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        try test.graph.voices.voiceLibrary?.savePrints([SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 10)], noteID: note.id)
        try test.graph.voices.saveSpeaker(noteID: note.id, speakerID: "a", name: "Alex", voiceID: nil, remember: true, renameSaved: false)
        XCTAssertEqual(test.graph.library.note(note.id)?.transcript.map(\.speaker), ["Alex", "Alex"])
        await test.graph.library.settle()

        let second = test.reopened()
        await second.graph.start()
        let voices = second.graph.voices, library = second.graph.library
        let voice = try XCTUnwrap(voices.savedVoices.first)
        voices.renameVoice(voice.id, name: "Alice")
        XCTAssertEqual(library.note(note.id)?.transcript.map(\.speaker), ["Alice", "Alice"])
        voices.forgetVoice(voice.id)
        XCTAssertTrue(voices.savedVoices.isEmpty)
        XCTAssertEqual(library.note(note.id)?.transcript.first?.speaker, "Alice")
        let generation = second.graph.settings.voicesGeneration
        voices.forgetAllVoices()
        XCTAssertGreaterThan(second.graph.settings.voicesGeneration, generation)
        let late = SpeakerAnalysis(turns: [.init(speakerID: "late", start: 0, end: 12)], prints: [.init(speakerID: "late", model: "test", vector: [1, 0], speechSeconds: 12)])
        try await voices.applySpeakerAnalysis(late, to: note.id, generation: generation)
        XCTAssertTrue(try voices.voiceLibrary?.prints(noteID: note.id).isEmpty == true, "an analysis from before Forget everyone keeps no voiceprints")

        let trash = second.graph.trash
        let moved = await trash.moveToTrash(note.id)
        XCTAssertTrue(moved)
        XCTAssertNotNil(library.note(note.id)?.trashedAt)
        trash.restore(note.id)
        XCTAssertNil(library.note(note.id)?.trashedAt)
        await trash.moveToTrash(note.id)
        await library.settle()
        test.clock.advance(by: .seconds(30 * 86_400))
        await trash.purgeExpired()
        XCTAssertNil(library.note(note.id))
        XCTAssertTrue(try voices.voiceLibrary?.prints(noteID: note.id).isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.root.appendingPathComponent(note.id.uuidString).path))
        XCTAssertEqual(second.graph.settings.trashLastPurgeAt, test.clock.now)
    }

    func testVoiceSuggestionsAutoNamingAndTrashedEvidence() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var source = Note(title: "Known person")
        source.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        source.transcript = [.init(text: "Reference", start: 0, end: 10, speaker: "Alex", speakerID: "a")]
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10)]
        try repository.save(source); try repository.save(target)
        await test.graph.start()
        let voices = test.graph.voices, library = test.graph.library, settings = test.graph.settings
        let print = SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 10)
        try voices.voiceLibrary?.savePrints([print], noteID: source.id)
        try voices.saveSpeaker(noteID: source.id, speakerID: "a", name: "Alex", voiceID: nil, remember: true, renameSaved: false)
        let voiceID = try XCTUnwrap(voices.savedVoices.first?.id)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print])
        let generation = settings.voicesGeneration
        settings.automaticallyNameVoices = false
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        XCTAssertEqual(library.note(target.id)?.speakers?.first?.suggestedVoiceID, voiceID)
        XCTAssertNil(library.note(target.id)?.speakers?.first?.linkedVoiceID)
        settings.automaticallyNameVoices = true
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        XCTAssertEqual(library.note(target.id)?.transcript.first?.speaker, "Alex")
        XCTAssertEqual(library.note(target.id)?.speakers?.first?.linkedVoiceID, voiceID)
        XCTAssertEqual(voices.savedVoices.first?.samples.count, 1, "An automatic match must not enroll new evidence")
        await test.graph.trash.moveToTrash(source.id)
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        XCTAssertNil(library.note(target.id)?.speakers?.first?.suggestedVoiceID)
        XCTAssertNil(library.note(target.id)?.speakers?.first?.linkedVoiceID)
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

    func testNamingASpeakerKeepsWhatAnEngineWriterSavedBeforeTheNameLanded() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Speaker session")
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a")]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        let library = test.graph.library
        let noteStore = try XCTUnwrap(library.noteStore)

        try test.graph.voices.saveSpeaker(noteID: note.id, speakerID: "a", name: "Alex", voiceID: nil, remember: false, renameSaved: false)
        // A transcription job saves the note before the name reaches the store.
        try await noteStore.mutate(note.id) { $0.status = .ready; $0.title = "Retitled by a job" }
        await library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.title, "Retitled by a job")
        XCTAssertEqual(stored.status, .ready)
        XCTAssertEqual(stored.speakers?.map(\.name), ["Alex"])
        XCTAssertEqual(stored.transcript.map(\.speaker), ["Alex"])
        XCTAssertEqual(library.note(note.id), stored)
        XCTAssertNil(test.graph.errors.current)
    }

    func testASpeakerAnalysisKeepsWhatAnEngineWriterSavedBeforeItLanded() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Conversation")
        note.status = .ready
        note.transcript = [.init(text: "First", start: 0, end: 4), .init(text: "Second", start: 5, end: 9)]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        let library = test.graph.library, voices = test.graph.voices
        let noteStore = try XCTUnwrap(library.noteStore)
        let analysis = SpeakerAnalysis(
            turns: [.init(speakerID: "x", start: 0, end: 4.5), .init(speakerID: "y", start: 4.5, end: 9)], prints: [])

        let analyzing = Task { try await voices.applySpeakerAnalysis(analysis, to: note.id, generation: test.graph.settings.voicesGeneration) }
        // An engine writer saves the note while the analysis is on its way to the store.
        try await noteStore.mutate(note.id) { $0.isFavorite = true; $0.title = "Retitled by a job" }
        try await analyzing.value
        await library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.title, "Retitled by a job")
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.speakers?.map(\.name), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(stored.transcript.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(stored.versions?.map(\.name), ["Before speaker analysis", "Speaker analysis"])
        XCTAssertEqual(stored.selectedVersionID, stored.versions?.last?.id)
        XCTAssertEqual(library.note(note.id), stored)
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
        graph.playback.load(try XCTUnwrap(graph.library.note(note.id)))
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
                        language: language, segments: [], doneMs: 0, totalMs: 2_000, elapsedMs: 1_000)
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

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
