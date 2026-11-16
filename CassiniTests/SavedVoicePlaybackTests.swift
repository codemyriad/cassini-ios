import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class SavedVoicePlaybackTests: XCTestCase {
    func testMeetingSamplesKeepSeparateSpeakerWindowsAndSavedPositionOnLeave() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = meeting()
        note.playbackPosition = 180
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        let alex = voice("Alex", note: note, speaker: "a"), camille = voice("Camille", note: note, speaker: "b")
        let samples = SavedVoicePlayback.samples(voices: [alex, camille], notes: [note], root: test.root)
        let first = try XCTUnwrap(samples[alex.id]), second = try XCTUnwrap(samples[camille.id])
        XCTAssertEqual(first.source.noteID, note.id)
        XCTAssertEqual(second.source.noteID, note.id)
        XCTAssertEqual(first.savedPosition, 180)
        XCTAssertEqual(second.savedPosition, 180)
        XCTAssertEqual(first.start, 10)
        XCTAssertEqual(first.end, 18)
        XCTAssertEqual(second.start, 20)
        XCTAssertEqual(second.end, 30)
        let playback = PlaybackStore(playback: FakePlayback(fileDuration: 240), library: test.graph.library)
        let owner = PlaybackOwner()
        playback.controller.show(first.source, at: first.savedPosition, owner: owner)
        XCTAssertTrue(playback.controller.playRange(first.source.noteID, from: first.start, to: first.end))
        playback.controller.show(second.source, at: second.savedPosition, owner: owner)
        XCTAssertTrue(playback.controller.playRange(second.source.noteID, from: second.start, to: second.end))
        playback.leave(owner)
        await playback.settle()
        await test.graph.library.settle()
        XCTAssertEqual(test.graph.library.note(note.id)?.playbackPosition, 180)
        XCTAssertEqual(try NoteRepository(root: test.root).load().notes.first?.playbackPosition, 180)
    }

    func testGuidedSampleUsesPrivateCAFWithoutAMeetingAndFallsBackWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = meeting()
        var saved = voice("Alex", note: note, speaker: "a")
        var guided = saved.samples[0]
        guided.noteID = UUID()
        guided.guidedEnrollment = true
        saved.samples.insert(guided, at: 0)
        let url = root.appendingPathComponent("PrivateVoices/Enrollment/\(saved.id.uuidString).caf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        let sample = try XCTUnwrap(SavedVoicePlayback.samples(voices: [saved], notes: [], root: root)[saved.id])
        XCTAssertEqual(sample.source.noteID, saved.id)
        XCTAssertEqual(sample.source.url, url)
        XCTAssertEqual(sample.savedPosition, 0)
        XCTAssertEqual(sample.start, 0)
        XCTAssertEqual(sample.end, 8)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(SavedVoicePlayback.samples(voices: [saved], notes: [], root: root).isEmpty)
        let fallback = try XCTUnwrap(SavedVoicePlayback.samples(voices: [saved], notes: [note], root: root)[saved.id])
        XCTAssertEqual(fallback.source.noteID, note.id)
    }

    func testLibrarySnapshotRefreshesForLoadingTrashingAndCompression() throws {
        let root = FileManager.default.temporaryDirectory
        var note = meeting()
        let saved = voice("Alex", note: note, speaker: "a")
        let original = SavedVoicePlayback.Snapshot(voices: [saved], notes: [note], root: root)
        XCTAssertTrue(SavedVoicePlayback.samples(voices: [saved], notes: [], root: root).isEmpty)
        XCTAssertNotEqual(original, .init(voices: [saved], notes: [], root: root))
        note.audioFilename = "audio.m4a"
        XCTAssertNotEqual(original, .init(voices: [saved], notes: [note], root: root))
        let compressed = try XCTUnwrap(SavedVoicePlayback.samples(voices: [saved], notes: [note], root: root)[saved.id])
        XCTAssertEqual(compressed.source.url.lastPathComponent, "audio.m4a")
        note.trashedAt = Date()
        XCTAssertNotEqual(original, .init(voices: [saved], notes: [note], root: root))
        XCTAssertTrue(SavedVoicePlayback.samples(voices: [saved], notes: [note], root: root).isEmpty)
        note.trashedAt = nil
        note.audio = .live
        XCTAssertTrue(SavedVoicePlayback.samples(voices: [saved], notes: [note], root: root).isEmpty)
        XCTAssertTrue(SavedVoicePlayback.samples(voices: [saved], notes: [meeting()], root: nil).isEmpty)
    }

    private func meeting() -> Note {
        var note = Note(title: "Meeting", audioFilename: "audio.caf")
        note.duration = 240
        note.transcript = [TranscriptSegment(text: "Hello", start: 10, end: 18, speakerID: "a"),
                           TranscriptSegment(text: "Bonjour", start: 20, end: 35, speakerID: "b")]
        return note
    }

    private func voice(_ name: String, note: Note, speaker: String) -> SavedVoice {
        SavedVoice(name: name, samples: [VoiceSample(noteID: note.id, print: SpeakerPrint(
            speakerID: speaker, model: VoiceprintModel.sha256, vector: [1], speechSeconds: 8))])
    }
}
