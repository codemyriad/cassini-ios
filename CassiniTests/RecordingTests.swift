import XCTest
import AVFoundation
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// Recording through the app graph: the Library's note mirror, the router, real CAF repair, inspection and M4A
/// compression.
@MainActor final class RecordingTests: XCTestCase {
    /// D95 saves position zero through LibraryRecordingNotes/LibraryStore while the controller is starting.
    /// The Library index and row projection must follow that mirror write and the subsequent active state.
    func testPositionZeroCommitKeepsTheActiveRecordingRowInSyncWithItsCard() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.returns([], total: 1), status: .unsupported),
                             audio: FakeAudioProcessing(duration: 2, opensAnyFile: true))
        defer { test.tearDown() }
        let graph = test.graph
        await graph.start()
        await graph.recording.start()
        await waitUntil { graph.recording.state.isActive }
        await graph.library.settle()
        await graph.libraryScreen.settle()
        let id = try XCTUnwrap(graph.recording.state.noteID)
        let mirrored = try XCTUnwrap(graph.library.note(id))
        let row = try XCTUnwrap(graph.libraryScreen.content.sections.flatMap(\.rows).first { $0.id == id })
        let card = try XCTUnwrap(graph.libraryScreen.recordingCard)
        XCTAssertEqual(card.noteID, id)
        XCTAssertEqual(row.status, .recording)
        XCTAssertTrue(row.isRecording)
        XCTAssertEqual(mirrored.audio, .live)
        XCTAssertNotNil(mirrored.meetingTime.instant)
        XCTAssertEqual(row.meetingTime, mirrored.meetingTime)
        let store = try XCTUnwrap(graph.library.noteStore)
        let storedNote = await store.note(id)
        let stored = try XCTUnwrap(storedNote)
        XCTAssertEqual(stored.meetingTime, mirrored.meetingTime)
        let persisted = try XCTUnwrap(try NoteRepository(root: test.root).load().notes.first { $0.id == id })
        XCTAssertEqual(persisted.meetingTime, mirrored.meetingTime)
        XCTAssertEqual(persisted.audio, .live)

        graph.recording.controller.pause()
        graph.recording.controller.resume()
        await graph.libraryScreen.settle()
        let resumed = try XCTUnwrap(graph.libraryScreen.content.sections.flatMap(\.rows).first { $0.id == id })
        XCTAssertEqual(resumed.status, .recording)
        XCTAssertTrue(resumed.isRecording)
        XCTAssertEqual(resumed.meetingTime, mirrored.meetingTime)

        graph.recording.screen.finish()
        await waitUntil { !graph.recording.state.inProgress }
        await graph.recording.controller.settle()
        await graph.library.settle()
    }

    func testUnavailableSpeechFinishesAudioOnlyWithoutAQueueOrConsentScreen() async throws {
        for consented in [false, true] {
            let test = TestGraph(transcriber: FakeTranscriber(.returns([], total: 1), status: .unsupported))
            defer { test.tearDown() }
            let graph = test.graph
            await graph.start()
            if consented { graph.settings.recordConsent() }
            await graph.recording.start()
            await waitUntil { graph.recording.state.isActive }
            let id = try XCTUnwrap(graph.recording.state.noteID)
            graph.recording.screen.finish()
            await waitUntil { graph.router.path == [.note(id)] }
            await graph.recording.controller.settle()
            await graph.library.settle()
            XCTAssertEqual(graph.router.path, [.note(id)])
            XCTAssertEqual(graph.library.note(id)?.status, .audioOnly)
            XCTAssertNil(graph.library.note(id)?.failure)
            XCTAssertTrue(try JobRepository(root: test.root).load().isEmpty)
            try await graph.processing.reconcileOnStart(activeNoteID: nil)
            XCTAssertNil(graph.library.note(id)?.failure, "launch repair must not invent an interrupted transcription")
            XCTAssertFalse(graph.notices.library(LibraryFacts(liveNotes: 1, audioOnly: true)).contains { $0.kind == .dlRecordNow })
        }
    }

    /// Two seconds of a tone in the recorder's format: 48 kHz 16-bit mono PCM in CAF.
    private func writeCapture(to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for index in 0..<96_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.3 }
        try file.write(from: buffer)
    }

    func testARecordingKilledMidCaptureIsRecoveredWithAPlayableDuration() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var note = Note(title: "Killed", audioFilename: "capture.caf")
        note.status = .recording; note.audio = .live
        try repository.save(note)
        let url = repository.audioURL(for: note)
        try writeCapture(to: url)
        // The process died before the CAF header was written: the data chunk claims all two seconds.
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count * 6 / 10).write(to: url)

        await test.graph.start()
        await test.graph.library.settle()
        let recovered = try XCTUnwrap(test.graph.library.note(note.id))
        XCTAssertEqual(recovered.audio, .plain)
        XCTAssertGreaterThan(recovered.duration, 1)
        XCTAssertLessThan(recovered.duration, 2)
        XCTAssertEqual(test.graph.recording.recovered.map(\.noteID), [note.id])
        let banner = try XCTUnwrap(test.graph.notices.library(LibraryFacts(loading: true)).first { $0.kind == .recovered })
        XCTAssertEqual(BannerCopy.title(banner), "1 recording recovered")
        XCTAssertEqual(banner.args.count, 1)
        XCTAssertFalse(test.graph.processing.state.isQueued(note.id), "recovery never queues")
    }

    func testADirectoryThatKeptItsAudioIsRebuiltBeforeTheLibraryLoads() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let id = UUID()
        let folder = test.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeCapture(to: folder.appendingPathComponent("capture.caf"))

        await test.graph.start()
        let note = try XCTUnwrap(test.graph.library.note(id))
        XCTAssertTrue(note.title.hasPrefix("Recovered recording "))
        XCTAssertEqual(note.origin, .recovered)
        XCTAssertEqual(note.duration, 2, accuracy: 0.01)
        XCTAssertEqual(test.graph.library.unreadableCount, 0)
        XCTAssertEqual(test.graph.recording.recovered.map(\.noteID), [id], "reported as a recovered recording")
    }

    func testFinishingARecordingOpensItsNoteCompressesAndQueuesIt() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let graph = test.graph
        await graph.start()
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false

        await graph.recording.start()
        XCTAssertEqual(graph.router.fullScreen, .recording)
        await waitUntil { graph.recording.state.isActive }
        let id = try XCTUnwrap(graph.recording.state.noteID)
        XCTAssertEqual(graph.library.note(id)?.audio, .live, "the Library shows the recording at once")
        XCTAssertEqual(graph.recording.screen.title, "Voice note 7 Oct, 09:41")
        XCTAssertEqual(test.liveActivity.started.map(\.noteID), [id])

        graph.recording.screen.finish()
        await waitUntil { graph.router.path == [.note(id)] }
        XCTAssertNil(graph.router.fullScreen)
        await graph.recording.controller.settle()
        await graph.library.settle()
        let note = try XCTUnwrap(graph.library.note(id))
        XCTAssertEqual(note.audio, .plain)
        XCTAssertEqual(note.title, "Voice note 7 Oct, 09:41")
        XCTAssertEqual(note.audioFilename, "audio.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.root.appendingPathComponent(id.uuidString).appendingPathComponent("capture.caf").path))
        await waitUntil { graph.processing.state.isQueued(id) || graph.processing.state.isRunning(id) || graph.library.note(id)?.status == .ready }
    }

    /// Android's `RecordingController.next`: with the speech model installed nothing needs consent, so a finished
    /// recording is queued even though no consent was ever recorded.
    func testAFinishedRecordingIsQueuedWhenTheModelIsInstalledWithoutRecordedConsent() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1, total: 2))); defer { test.tearDown() }
        let graph = test.graph
        await graph.start()
        graph.settings.identifySpeakers = false
        XCTAssertNil(graph.settings.modelsConsentAt)

        await graph.recording.start()
        await waitUntil { graph.recording.state.isActive }
        let id = try XCTUnwrap(graph.recording.state.noteID)
        graph.recording.screen.finish()
        await waitUntil { graph.processing.state.isRunning(id) }
        XCTAssertEqual(graph.router.path, [.note(id)], "nothing to ask")
        graph.processing.stopAll()
    }

    func testAFinishedRecordingWithoutConsentOrInstalledModelOffersTheDownload() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.returns([], total: 1), status: .notDownloaded))
        defer { test.tearDown() }
        let graph = test.graph
        await graph.start()

        await graph.recording.start()
        await waitUntil { graph.recording.state.isActive }
        let id = try XCTUnwrap(graph.recording.state.noteID)
        graph.recording.screen.finish()
        await waitUntil { graph.router.path == [.note(id), .modelDownload(noteID: id)] }
        await graph.recording.controller.settle()
        XCTAssertNil(graph.processing.state.jobs[id], "asking queues nothing")
        XCTAssertEqual(graph.library.note(id)?.status, .audioOnly)
    }

    func testTheLiveActivityButtonsControlTheRecording() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let graph = test.graph
        await graph.start()
        await graph.recording.start()
        await waitUntil { graph.recording.state.isActive }
        let id = try XCTUnwrap(graph.recording.state.noteID)
        RecordingIntentRouter.perform(.pause, noteID: UUID().uuidString)
        XCTAssertNil(graph.recording.state.activeRecording?.pause, "an activity of another recording does nothing")
        RecordingIntentRouter.perform(.pause, noteID: id.uuidString)
        XCTAssertEqual(graph.recording.state.activeRecording?.pause, .user)
        XCTAssertEqual(test.liveActivity.updates.last?.isPaused, true)
        RecordingIntentRouter.perform(.resume, noteID: id.uuidString)
        XCTAssertNil(graph.recording.state.activeRecording?.pause)
        graph.router.dismissRecording()
        graph.recording.returnToRecording()
        XCTAssertEqual(graph.router.fullScreen, .recording)
        RecordingIntentRouter.perform(.finish, noteID: id.uuidString)
        await waitUntil { if case .note = graph.router.path.last { true } else { false } }
        XCTAssertFalse(test.liveActivity.isRunning)
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
