import XCTest
import AVFoundation
import CassiniNotebook
import CassiniAudio
import CassiniCore
import CassiniInference
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
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        var recording = Note(title: "Interrupted recording", audioFilename: "capture.caf")
        recording.status = .recording
        try repository.save(recording)
        try writeSignal(to: repository.audioURL(for: recording))
        var transcribing = Note(title: "Interrupted transcription")
        transcribing.status = .transcribing
        transcribing.transcript = [.init(text: "Keep this earlier transcript.", start: 0, end: 1)]
        try repository.save(transcribing)
        let store = AppStore(rootURL: root)
        await store.recoverInterruptedWork()
        XCTAssertEqual(store.note(recording.id)?.status, .audioOnly)
        XCTAssertEqual(store.note(recording.id)?.duration ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(store.note(transcribing.id)?.status, .ready)
        XCTAssertEqual(store.note(transcribing.id)?.text, "Keep this earlier transcript.")
        XCTAssertNotNil(store.note(transcribing.id)?.failureMessage)
        let saved = try repository.load().notes
        XCTAssertFalse(saved.contains { $0.status == .recording || $0.status == .transcribing })
    }
    @MainActor func testImportCopiesM4AWithoutChangingTheSource() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.caf")
        let compressed = root.appendingPathComponent("An imported conversation.m4a")
        try writeSignal(to: source)
        try await AudioArchive.compress(source: source, destination: compressed)
        let store = AppStore(rootURL: root.appendingPathComponent("Library"))
        let automatic = store.autoTranscribe; store.autoTranscribe = false
        defer { store.autoTranscribe = automatic }
        await store.importAudio(compressed)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.notes.count, 1)
        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(imported.title, "An imported conversation")
        XCTAssertEqual(imported.audioFilename, "audio.m4a")
        XCTAssertEqual(imported.duration, 2, accuracy: 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path))
        XCTAssertNotEqual(store.audioURL(imported), compressed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.audioURL(imported)).path))
    }
    @MainActor func testVoiceNamingPersistenceForgetAndTrashExpiry() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        var note = Note(title: "Speaker session")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"), .init(text: "Again", start: 9, end: 12, speaker: "Speaker 1", speakerID: "a")]
        try repository.save(note)
        let store = AppStore(rootURL: root)
        try store.voiceLibrary?.savePrints([SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 10)], noteID: note.id)
        XCTAssertTrue(store.saveSpeaker(noteID: note.id, speakerID: "a", name: "Alex", voiceID: nil, remember: true, renameSaved: false))
        XCTAssertEqual(store.note(note.id)?.transcript.map(\.speaker), ["Alex", "Alex"])
        let reopened = AppStore(rootURL: root)
        let voice = try XCTUnwrap(reopened.savedVoices.first)
        reopened.renameVoice(voice.id, name: "Alice")
        XCTAssertEqual(reopened.note(note.id)?.transcript.map(\.speaker), ["Alice", "Alice"])
        reopened.forgetVoice(voice.id)
        XCTAssertTrue(reopened.savedVoices.isEmpty)
        XCTAssertEqual(reopened.note(note.id)?.transcript.first?.speaker, "Alice")
        let generation = reopened.voiceGeneration
        reopened.forgetAllVoices()
        XCTAssertGreaterThan(reopened.voiceGeneration, generation)
        let late = SpeakerAnalysis(turns: [.init(speakerID: "late", start: 0, end: 12)], prints: [.init(speakerID: "late", model: "test", vector: [1, 0], speechSeconds: 12)])
        try reopened.applySpeakerAnalysis(late, to: note.id, allowEvidence: generation == reopened.voiceGeneration)
        XCTAssertTrue(try reopened.voiceLibrary?.prints(noteID: note.id).isEmpty == true)
        reopened.trash(note.id)
        XCTAssertNotNil(reopened.note(note.id)?.trashedAt)
        reopened.restore(note.id)
        XCTAssertNil(reopened.note(note.id)?.trashedAt)
        reopened.trash(note.id)
        let deletion = try XCTUnwrap(reopened.note(note.id)?.trashedAt)
        reopened.purgeExpiredTrash(now: Calendar.current.date(byAdding: .day, value: 30, to: deletion)!)
        XCTAssertNil(reopened.note(note.id))
        XCTAssertTrue(try reopened.voiceLibrary?.prints(noteID: note.id).isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: note.id).path))
    }

    @MainActor func testPortableExportReimportPlaysAndPreservesSource() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("capture.caf")
        try writeSignal(to: source)
        let store = AppStore(rootURL: root.appendingPathComponent("Library"))
        let automatic = store.autoTranscribe; store.autoTranscribe = false
        defer { store.autoTranscribe = automatic }
        await store.importAudio(source)
        let id = try XCTUnwrap(store.notes.first?.id)
        store.update(id) { note in
            note.transcript = [.init(text: "Hello there", start: 0, end: 1.5, speaker: "Alex", speakerID: "a")]
            note.speakers = [NoteSpeaker(id: "a", name: "Alex")]; note.status = .ready
        }
        let portable = try await store.exportPortable(id)
        defer { try? FileManager.default.removeItem(at: portable.deletingLastPathComponent()) }
        XCTAssertEqual(CassiniDocument.read(portable).state, "ok")
        let original = try Data(contentsOf: portable)
        await store.importAudio(portable)
        XCTAssertNil(store.errorMessage)
        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertNotEqual(imported.id, id)
        XCTAssertEqual(imported.audioFilename, "playback.caf")
        XCTAssertEqual(imported.originalAudioFilename, "audio.opus")
        XCTAssertNil(imported.playbackUnavailable)
        XCTAssertEqual(imported.transcript.first?.speaker, "Alex")
        XCTAssertEqual(imported.duration, 2, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.originalAudioURL(imported))), original)
        XCTAssertEqual(try Data(contentsOf: portable), original)
        store.loadPlayer(imported)
        XCTAssertEqual(store.player.noteID, imported.id)
    }

    @MainActor func testVoiceSuggestionsAutoNamingAndTrashedEvidence() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        var source = Note(title: "Known person")
        source.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        source.transcript = [.init(text: "Reference", start: 0, end: 10, speaker: "Alex", speakerID: "a")]
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10)]
        try repository.save(source); try repository.save(target)
        let store = AppStore(rootURL: root)
        let automatic = store.automaticallyNameVoices; defer { store.automaticallyNameVoices = automatic }
        let print = SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 10)
        try store.voiceLibrary?.savePrints([print], noteID: source.id)
        XCTAssertTrue(store.saveSpeaker(noteID: source.id, speakerID: "a", name: "Alex", voiceID: nil, remember: true, renameSaved: false))
        let voiceID = try XCTUnwrap(store.savedVoices.first?.id)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print])
        store.automaticallyNameVoices = false
        try store.applySpeakerAnalysis(analysis, to: target.id)
        XCTAssertEqual(store.note(target.id)?.speakers?.first?.suggestedVoiceID, voiceID)
        XCTAssertNil(store.note(target.id)?.speakers?.first?.voiceID)
        store.automaticallyNameVoices = true
        try store.applySpeakerAnalysis(analysis, to: target.id)
        XCTAssertEqual(store.note(target.id)?.transcript.first?.speaker, "Alex")
        XCTAssertEqual(store.note(target.id)?.speakers?.first?.voiceID, voiceID)
        XCTAssertEqual(store.savedVoices.first?.samples.count, 1, "An automatic match must not enroll new evidence")
        store.trash(source.id)
        try store.applySpeakerAnalysis(analysis, to: target.id)
        XCTAssertNil(store.note(target.id)?.speakers?.first?.suggestedVoiceID)
        XCTAssertNil(store.note(target.id)?.speakers?.first?.voiceID)
    }

}
