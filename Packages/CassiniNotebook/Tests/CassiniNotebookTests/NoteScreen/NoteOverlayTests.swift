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

    /// As Android keeps the typed title (RenameDialog `rememberSaveable`) and the name being typed.
    @Test func nameThisSpeakerAndRenameKeepWhatWasTyped() {
        let note = note()
        let naming = SavedNoteOverlay(noteID: note.id, overlay: .naming(speakerID: "a"), draft: "Giu")
        #expect(naming.restored(over: note, readOnly: nil)?.draft == "Giu")
        let rename = SavedNoteOverlay(noteID: note.id, overlay: .rename, draft: "Standup, revised")
        #expect(rename.restored(over: note, readOnly: nil)?.draft == "Standup, revised")
        let speakers = SavedNoteOverlay(noteID: note.id, overlay: .speakers, draft: "stray")
        #expect(speakers.restored(over: note, readOnly: nil) == SavedNoteOverlay(noteID: note.id, overlay: .speakers))
        let kept = SavedNoteOverlay.keeping(noteID: note.id, overlay: .speakers, draft: "stray", dialog: nil)
        #expect(SavedNoteOverlay(kept) == SavedNoteOverlay(noteID: note.id, overlay: .speakers))
    }

    @Test func nothingOpenKeepsNothing() {
        #expect(SavedNoteOverlay.keeping(noteID: UUID(), overlay: nil, draft: "Giu", dialog: nil) == nil)
    }

    /// What does not come back is not kept either: the screen drops it, so it never opens by itself on a later visit.
    @Test func aSavedSheetThatCannotOpenNowLeavesNothingToKeep() {
        let note = note()
        let speakers = SavedNoteOverlay(noteID: note.id, overlay: .speakers)
        #expect(speakers.restored(over: note, readOnly: .jobPending) == nil, "a transcription runs at relaunch")
        let rename = SavedNoteOverlay(noteID: note.id, overlay: .rename, dialog: .readOnly(.jobPending))
        #expect(rename.restored(over: note, readOnly: nil) == SavedNoteOverlay(noteID: note.id, overlay: .rename),
                "the sheet comes back without the question that no longer applies")
    }

    /// As Android keeps its dialog (NoteViewModel.savedDialog), while it still applies.
    @Test func theOpenQuestionComesBackWhileItApplies() {
        let note = note()
        func restored(_ dialog: NoteDialog, over note: Note, readOnly: ReadOnlyReason?) -> NoteDialog? {
            SavedNoteOverlay(noteID: note.id, dialog: dialog).restored(over: note, readOnly: readOnly)?.dialog
        }
        #expect(SavedNoteOverlay(SavedNoteOverlay.keeping(noteID: note.id, overlay: nil, draft: nil,
                                                          dialog: .readOnly(.trust)))?.dialog == .readOnly(.trust))
        #expect(restored(.startOver, over: note, readOnly: .jobPending) == .startOver)
        #expect(restored(.readOnly(.jobPending), over: note, readOnly: .jobPending) == .readOnly(.jobPending))
        #expect(restored(.readOnly(.jobPending), over: note, readOnly: nil) == nil, "the transcription finished")
        #expect(restored(.transcribeFresh, over: note, readOnly: nil) == nil, "a recording keeps its versions")
        var stale = note
        stale.document = DocumentInfo(state: .staleAudio)
        #expect(restored(.transcribeFresh, over: stale, readOnly: .trust) == .transcribeFresh)
    }
}
