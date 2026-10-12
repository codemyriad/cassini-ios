import Foundation
import Testing
import CassiniNotebook

/// When a Note screen shows the player and what it follows (Android's `NoteMapping.hasPlayer`, which Android tests
/// through the Note screen's modes).
struct NotePlayerTests {
    private func note(audio: AudioState = .plain, status: NoteStatus = .ready) -> Note {
        var note = Note(title: "Note", audioFilename: "capture.caf")
        note.audio = audio; note.status = status; note.duration = 12
        return note
    }

    // ports: NoteViewModelTest#aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer
    @Test func aPlainNoteHasAPlayerAndAnUnplayableOneHasNone() {
        #expect(NotePlayer.hasPlayer(note()))
        #expect(NotePlayer.hasPlayer(note(status: .audioOnly)))
        #expect(!NotePlayer.hasPlayer(note(audio: .unplayable(.unsupportedFormat))))
        #expect(!NotePlayer.hasPlayer(note(audio: .unplayable(.interrupted))))
        #expect(!NotePlayer.hasPlayer(note(audio: .live)), "a capture is still writing the file")
    }

    @Test func aNoteBeingTranscribedHasNoPlayerButAQueuedOrFailedOneHas() {
        #expect(!NotePlayer.hasPlayer(note(status: .transcribing)))
        #expect(NotePlayer.hasPlayer(note(status: .queued)))
        #expect(NotePlayer.hasPlayer(note(status: .failed)))
    }

    @Test func theKeyFollowsTheFileAndIsNoneWhileARecordingKeepsThePlayerClosed() {
        let plain = note()
        let key = NotePlayer.key(for: plain, blocked: false)
        #expect(key?.noteID == plain.id)
        #expect(key?.audioFilename == "capture.caf")
        #expect(NotePlayer.key(for: plain, blocked: true) == nil, "a recording runs")
        #expect(NotePlayer.key(for: nil, blocked: false) == nil)
        #expect(NotePlayer.key(for: note(status: .transcribing), blocked: false) == nil)

        var compressed = plain
        compressed.audioFilename = "audio.m4a"
        #expect(NotePlayer.key(for: compressed, blocked: false) != key, "the compressed copy reloads")
        var sealed = plain
        sealed.duration = 13
        #expect(NotePlayer.key(for: sealed, blocked: false) != key)
        #expect(NotePlayer.key(for: plain, blocked: false) == key)
    }
}
