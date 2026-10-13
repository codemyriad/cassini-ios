import Foundation
import Testing
@testable import CassiniNotebook

/// The Note screen's open sheet comes back after Cassini was closed, unless what it was about is gone.
@Suite struct NoteOverlayTests {
    private func note() -> Note {
        var note = Note(title: "Standup")
        note.transcript = [TranscriptSegment(text: "Hello there", start: 0, end: 1, speakerID: "a")]
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        return note
    }

    @Test func aSavedSheetRoundTripsWithItsDraft() throws {
        let saved = SavedNoteOverlay(noteID: UUID(), overlay: .naming(speakerID: "a"), draft: "Giu")
        #expect(SavedNoteOverlay(saved.encoded) == saved)
        #expect(SavedNoteOverlay(Data("garbage".utf8)) == nil)
        #expect(SavedNoteOverlay(nil) == nil)
    }

    @Test func eachSheetComesBackOverItsNote() {
        let note = note()
        var withVersions = note
        withVersions.saveCurrentVersion(.transcription)
        let segment = note.transcript[0].id
        for overlay in [NoteOverlay.rename, .documentInfo, .speakers, .naming(speakerID: "a"), .editing(segmentID: segment)] {
            #expect(overlay.restorable(over: note, readOnly: nil) == overlay, "\(overlay)")
        }
        #expect(NoteOverlay.versions.restorable(over: withVersions, readOnly: nil) == .versions)
    }

    @Test func aSheetAboutSomethingGoneDoesNotComeBack() {
        let note = note()
        #expect(NoteOverlay.naming(speakerID: "b").restorable(over: note, readOnly: nil) == nil, "the speaker was merged away")
        #expect(NoteOverlay.editing(segmentID: UUID()).restorable(over: note, readOnly: nil) == nil, "the passage changed")
        #expect(NoteOverlay.versions.restorable(over: note, readOnly: nil) == nil, "no version is kept")
        let other = SavedNoteOverlay(noteID: UUID(), overlay: .rename)
        #expect(other.restored(over: note, readOnly: nil) == nil, "another note's sheet")
    }

    @Test func aSheetThatChangesTheTranscriptWaitsWhileItIsReadOnly() {
        let note = note()
        for overlay in [NoteOverlay.speakers, .naming(speakerID: "a"), .editing(segmentID: note.transcript[0].id)] {
            #expect(overlay.restorable(over: note, readOnly: .jobPending) == nil, "\(overlay)")
        }
        #expect(NoteOverlay.rename.restorable(over: note, readOnly: .jobPending) == .rename)
        #expect(NoteOverlay.documentInfo.restorable(over: note, readOnly: .trust) == .documentInfo)
    }

    @Test func onlyNameThisSpeakerKeepsADraft() {
        let note = note()
        let naming = SavedNoteOverlay(noteID: note.id, overlay: .naming(speakerID: "a"), draft: "Giu")
        #expect(naming.restored(over: note, readOnly: nil)?.draft == "Giu")
        let rename = SavedNoteOverlay(noteID: note.id, overlay: .rename, draft: "stray")
        #expect(rename.restored(over: note, readOnly: nil) == SavedNoteOverlay(noteID: note.id, overlay: .rename))
    }
}
