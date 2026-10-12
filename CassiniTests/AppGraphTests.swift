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

    func testBackgroundExpiryPausesTheJobHoldsTheQueueAndEndsTheTaskBeforeReturning() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 5, total: 10)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
        graph.settings.identifySpeakers = false
        XCTAssertEqual(await graph.processing.transcribe(note.id), .queued(changed: true))
        await waitUntil { graph.processing.state.running?.fraction == 0.5 }
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

    func testAFinishedJobSavesTheTranscriptAndEndsItsBackgroundTask() async throws {
        let words = [TranscriptSegment(text: "Hello there.", start: 0, end: 1)]
        let test = TestGraph(transcriber: FakeTranscriber(.returns(words, total: 2)))
        defer { test.tearDown() }
        let note = try await seedPlainNote(in: test)
        let graph = test.graph
        graph.settings.downloadsAllowed = true
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
        XCTAssertEqual(await test.graph.processing.transcribe(note.id), .needsConsent)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.state, .needsConsent)
        XCTAssertNil(test.graph.processing.state.running)
    }

    /// An analysis that began before Forget everyone keeps no voiceprints, even though it finishes after it.
    func testASpeakerAnalysisThatStartedBeforeForgetEveryoneKeepsNoVoiceprints() async throws {
        let late = SpeakerAnalysis(turns: [.init(speakerID: "late", start: 0, end: 12)],
                                   prints: [.init(speakerID: "late", model: "test", vector: [1, 0], speechSeconds: 12)])
        let analyzer = FakeAnalyzer(analysis: late, suspends: true)
        let test = TestGraph(analyzer: analyzer); defer { test.tearDown() }
        var note = Note(title: "Conversation", audioFilename: "audio.caf")
        note.status = .ready
        note.transcript = [.init(text: "Hello", start: 0, end: 12)]
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        let graph = test.graph
        graph.settings.speakerDownloadsAllowed = true

        XCTAssertEqual(await graph.processing.transcribe(note.id, kind: .speakersOnly), .queued(changed: true))
        await waitUntil { analyzer.analyzeCount == 1 }
        graph.voices.forgetAllVoices()
        analyzer.resume()
        await graph.processing.coordinator?.awaitIdle()
        await graph.library.settle()

        XCTAssertEqual(graph.library.note(note.id)?.speakers?.count, 1, "the speakers are still told apart")
        XCTAssertTrue(try graph.voices.voiceLibrary?.prints(noteID: note.id).isEmpty == true)
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
        XCTAssertTrue(try voices.voiceLibrary?.prints(noteID: note.id).isEmpty == true)

        let trash = second.graph.trash
        XCTAssertTrue(trash.moveToTrash(note.id))
        XCTAssertNotNil(library.note(note.id)?.trashedAt)
        trash.restore(note.id)
        XCTAssertNil(library.note(note.id)?.trashedAt)
        trash.moveToTrash(note.id)
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
        test.graph.trash.moveToTrash(source.id)
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
        XCTAssertTrue(graph.trash.moveToTrash(note.id))
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
        var note = Note(title: "Plain", audioFilename: "audio.caf")
        note.duration = 2
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        return note
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
