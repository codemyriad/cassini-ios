import XCTest
import AVFoundation
import CassiniNotebook
import CassiniAudio
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

final class AudioPipelineTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSignal(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2 }
        try file.write(from: buffer); try file.write(from: buffer)
    }

    func testCAFInspectionAndM4ACompressionPreserveAudio() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("capture.caf")
        let output = root.appendingPathComponent("audio.m4a")
        try writeSignal(to: source)
        let before = try await AudioInspection.inspect(source)
        XCTAssertEqual(before.duration, 2, accuracy: 0.001)
        XCTAssertEqual(before.waveform.count, 96)
        XCTAssertTrue(before.waveform.allSatisfy { $0 > 0.1 && $0 <= 1 })
        try await AudioArchive.compress(source: source, destination: output)
        let after = try await AudioInspection.inspect(output)
        XCTAssertEqual(after.duration, 2, accuracy: 0.1)
        XCTAssertTrue(after.waveform.allSatisfy { $0 > 0.1 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testInvalidAudioIsRejected() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: url)
        do { _ = try await AudioInspection.inspect(url); XCTFail("Invalid audio must not be accepted") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    @MainActor func testInterruptedCaptureAndTranscriptionRecovery() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var recording = Note(title: "Interrupted recording", audioFilename: "capture.caf")
        recording.status = .recording; recording.audio = .live
        try repository.save(recording)
        try writeSignal(to: repository.audioURL(for: recording))
        var transcribing = Note(title: "Interrupted transcription")
        transcribing.status = .transcribing
        transcribing.transcript = [.init(text: "Keep this earlier transcript.", start: 0, end: 1)]
        try repository.save(transcribing)
        let store = test.graph.library
        await test.graph.start()
        await store.settle()
        XCTAssertEqual(store.note(recording.id)?.status, .audioOnly)
        XCTAssertEqual(store.note(recording.id)?.audio, .plain)
        XCTAssertEqual(store.note(recording.id)?.duration ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(store.note(transcribing.id)?.status, .ready)
        XCTAssertEqual(store.note(transcribing.id)?.text, "Keep this earlier transcript.")
        XCTAssertEqual(store.note(transcribing.id)?.failure, .interrupted)
        let saved = try repository.load().notes
        XCTAssertFalse(saved.contains { $0.status == .recording || $0.status == .transcribing })
    }

    @MainActor func testImportCopiesM4AWithoutChangingTheSource() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("Original.caf")
        let compressed = sources.appendingPathComponent("An imported conversation.m4a")
        try writeSignal(to: source)
        try await AudioArchive.compress(source: source, destination: compressed)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        await test.graph.imports.importAudio(compressed)
        let store = test.graph.library
        XCTAssertNil(test.graph.errors.current)
        XCTAssertEqual(store.notes.count, 1)
        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(imported.title, "An imported conversation")
        XCTAssertEqual(imported.audioFilename, "audio.m4a")
        XCTAssertEqual(imported.origin, .imported)
        XCTAssertEqual(imported.duration, 2, accuracy: 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path))
        XCTAssertNotEqual(store.audioURL(imported), compressed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.audioURL(imported)).path))
        XCTAssertEqual(test.graph.router.path, [.note(imported.id)])
    }

    @MainActor func testPortableExportReimportPlaysAndPreservesSource() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("capture.caf")
        try writeSignal(to: source)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let store = test.graph.library
        await test.graph.imports.importAudio(source)
        let id = try XCTUnwrap(store.notes.first?.id)
        await store.commit(id) { note in
            note.transcript = [.init(text: "Hello there", start: 0, end: 1.5, speaker: "Alex", speakerID: "a")]
            note.speakers = [NoteSpeaker(id: "a", name: "Alex")]; note.status = .ready
        }
        let portable = try await test.graph.exports.exportPortable(id)
        defer { try? FileManager.default.removeItem(at: portable.deletingLastPathComponent()) }
        XCTAssertEqual(CassiniDocument.read(portable).state, "ok")
        let original = try Data(contentsOf: portable)
        test.clock.advance(by: .seconds(60))
        await test.graph.imports.importAudio(portable)
        XCTAssertNil(test.graph.errors.current)
        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertNotEqual(imported.id, id)
        XCTAssertEqual(imported.origin, .importedDocument)
        XCTAssertEqual(imported.audioFilename, "playback.caf")
        XCTAssertEqual(imported.originalAudioFilename, "audio.opus")
        XCTAssertEqual(imported.audio, .plain)
        XCTAssertEqual(imported.transcript.first?.speaker, "Alex")
        XCTAssertEqual(imported.duration, 2, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.originalAudioURL(imported))), original)
        XCTAssertEqual(try Data(contentsOf: portable), original)
        test.graph.playback.load(imported)
        XCTAssertEqual(test.graph.playback.state.noteID, imported.id)
        XCTAssertEqual(test.playback.loadedURL, store.audioURL(imported))
    }
}
