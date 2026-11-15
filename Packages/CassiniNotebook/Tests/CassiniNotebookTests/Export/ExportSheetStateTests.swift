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
    func firstRunStatesHideText(_ status: NoteStatus) {
        var note = Note(title: "Draft")
        note.status = status
        note.versions = []
        note.selectedVersionID = UUID()
        let state = ExportSheetState(note: note, jobPending: true)
        #expect(state.primary == [.cassiniFile])
        #expect(state.moreFormats.isEmpty && state.audioOnly)
        #expect(TranscriptExports.availability(of: note) == .afterTranscription)
        #expect(ExportSheetState.portableSnapshot(note).transcript.isEmpty)
        #expect(ExportSheetState.portableSnapshot(note).versions?.isEmpty == true)
        #expect(ExportSheetState.portableSnapshot(note).selectedVersionID == nil)
        note.origin = .imported
        #expect(ExportSheetState(note: note, jobPending: true).primary == [.originalAudio])
    }
    @Test func importedAudioAndPendingJobs() {
        var note = Note(title: "Import")
        note.origin = .imported
        #expect(ExportSheetState(note: note).primary == [.originalAudio])
        #expect(ExportSheetState(note: note).selection == .originalAudio)
        note.status = .ready
        #expect(ExportSheetState(note: note).primary == [.cassiniFile, .markdown])
        #expect(ExportSheetState(note: note, jobPending: true).primary == [.cassiniFile, .markdown])
        note.origin = .importedDocument
        #expect(ExportSheetState(note: note, jobPending: true).primary == [.cassiniFile, .markdown])
    }
}

extension ExportSheetStateTests {
    @Test(arguments: [NoteStatus.ready, .queued, .transcribing, .failed], [false, true])
    func finishedTranscriptRemainsAvailable(status: NoteStatus, pending: Bool) {
        for evidence in 0..<3 {
            var note = Note(title: "Finished")
            note.status = status
            if evidence == 0 {
                note.transcript = [.init(text: "Hand edited", start: 0, end: 1)]
            } else if evidence == 1 {
                note.versions = [.init(kind: .transcription, segments: [], speakers: [])]
                note.selectedVersionID = note.versions?.first?.id
            } else {
                note.status = .ready // A completed no-speech result without versions.
            }
            #expect(note.hasFinishedTranscript)
            #expect(TranscriptExports.availability(of: note) == .available)
            #expect(!ExportSheetState(note: note, jobPending: pending).audioOnly)
            #expect(ExportSheetState.portableSnapshot(note) == note)
        }
    }
}
