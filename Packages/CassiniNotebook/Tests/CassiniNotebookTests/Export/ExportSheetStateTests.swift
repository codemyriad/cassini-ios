import Foundation
import Testing
@testable import CassiniNotebook

struct ExportSheetStateTests {
    @Test func completedChoices() {
        var note = Note(title: "Meeting")
        note.status = .ready
        let state = ExportSheetState(note: note)
        #expect(state.primary == [.cassiniFile, .markdown])
        #expect(state.moreFormats == [.plainText, .srt, .vtt])
        #expect(state.selection == .cassiniFile)
        #expect(!state.audioOnly)
        #expect(!(state.primary + state.moreFormats).compactMap(\.transcriptFormat).contains(.json))
    }
    @Test(arguments: [NoteStatus.audioOnly, .queued, .transcribing, .failed, .recording])
    func incompleteStatesHideTextAndStripDrafts(_ status: NoteStatus) {
        var note = Note(title: "Draft")
        note.status = status
        note.transcript = [TranscriptSegment(text: "Partial words", start: 0, end: 1)]
        let state = ExportSheetState(note: note)
        #expect(state.primary == [.cassiniFile])
        #expect(state.moreFormats.isEmpty && state.audioOnly)
        #expect(TranscriptExports.availability(of: note) == .afterTranscription)
        #expect(ExportSheetState.portableSnapshot(note).transcript.isEmpty)
        #expect(ExportSheetState.portableSnapshot(note).versions?.isEmpty == true)
    }
    @Test func importedAudioAndPendingJobs() {
        var note = Note(title: "Import")
        note.origin = .imported
        #expect(ExportSheetState(note: note).primary == [.originalAudio])
        #expect(ExportSheetState(note: note).selection == .originalAudio)
        note.status = .ready
        #expect(ExportSheetState(note: note).primary == [.cassiniFile, .markdown])
        #expect(ExportSheetState(note: note, jobPending: true).primary == [.originalAudio])
        note.origin = .importedDocument
        #expect(ExportSheetState(note: note, jobPending: true).primary == [.cassiniFile])
    }
}
