import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android `NoteStatusTest`, plus the facts iOS reads from a note.
struct RowStatusTests {
    private func status(_ kind: AudioKind, _ document: DocumentState? = nil, job: JobState? = nil, active: Bool = false) -> RowStatus {
        RowStatus.of(RowFacts(audioKind: kind, documentState: document, jobState: job, isActiveCapture: active))
    }

    // ports: NoteStatusTest#recordingOnlyForTheActiveCapture
    @Test func recordingOnlyForTheActiveCapture() {
        #expect(status(.liveCapture, active: true) == .recording)
        #expect(status(.liveCapture, active: false) == .audioOnly)
        // The active flag alone does not make a recording: only a live capture is one.
        #expect(status(.plain, active: true) == .audioOnly)
    }

    // ports: NoteStatusTest#jobRows
    @Test func jobRows() {
        #expect(status(.plain, job: .running) == .transcribing)
        #expect(status(.plain, job: .queued) == .queued)
        #expect(status(.plain, job: .paused) == .paused)
        #expect(status(.plain, job: .failed) == .failed)
        #expect(status(.plain, job: .needsConsent) == .audioOnly)
    }

    // ports: NoteStatusTest#audioAndDocumentRows
    @Test func audioAndDocumentRows() {
        #expect(status(.unplayable) == .unplayable)
        #expect(status(.document, .unreadable) == .unreadable)
        #expect(status(.document, .invalidMetadata) == .unreadable)
        #expect(status(.document, .unknownFormat) == .newerFormat)
        #expect(status(.document, .ok) == .transcribed)
        #expect(status(.document, .unverified) == .transcribed)
        #expect(status(.document, .staleAudio) == .transcribed)
        #expect(status(.document, .plainAudio) == .audioOnly)
        #expect(status(.plain) == .audioOnly)
    }

    // ports: NoteStatusTest#firstMatchWins
    @Test func firstMatchWins() {
        #expect(status(.liveCapture, job: .running, active: true) == .recording)
        #expect(status(.unplayable, job: .running) == .transcribing)
        #expect(status(.document, .ok, job: .queued) == .queued)
        #expect(status(.document, .unreadable, job: .paused) == .paused)
        #expect(status(.document, .unknownFormat, job: .failed) == .failed)
        #expect(status(.unplayable, .ok) == .unplayable)
        #expect(status(.document, .ok, job: .needsConsent) == .transcribed)
        #expect(status(.document, .invalidMetadata, job: .needsConsent) == .unreadable)
    }

    // ports: NoteStatusTest#everyCombinationHasAStatus
    @Test func everyCombinationHasAStatus() {
        let documents: [DocumentState?] = [nil] + DocumentState.allCases
        let jobs: [JobState?] = [nil] + JobState.allCases
        let all = AudioKind.allCases.flatMap { kind in
            documents.flatMap { document in jobs.flatMap { job in [true, false].map { status(kind, document, job: job, active: $0) } } }
        }
        #expect(all.count == AudioKind.allCases.count * documents.count * jobs.count * 2)
        #expect(Set(all) == Set(RowStatus.allCases))
    }

    // ports: NoteStatusTest#suffixes
    @Test func suffixes() {
        #expect(RowStatus.suffix(.paused, speakerCount: 0, hasWords: false) == .resume)
        #expect(RowStatus.suffix(.failed, speakerCount: 0, hasWords: false) == .tryAgain)
        #expect(RowStatus.suffix(.transcribed, speakerCount: 3, hasWords: true) == .speakers)
        #expect(RowStatus.suffix(.transcribed, speakerCount: 2, hasWords: true) == .speakers)
        #expect(RowStatus.suffix(.transcribed, speakerCount: 1, hasWords: true) == .speakers)
        #expect(RowStatus.suffix(.transcribed, speakerCount: 0, hasWords: true) == .none)
        #expect(RowStatus.suffix(.transcribed, speakerCount: 0, hasWords: false) == .noSpeech)
        #expect(RowStatus.suffix(.transcribed, speakerCount: 3, hasWords: false) == .noSpeech)
        #expect(RowStatus.suffix(.audioOnly, speakerCount: 0, hasWords: false) == .none)
        #expect(RowStatus.suffix(.transcribing, speakerCount: 3, hasWords: true) == .none)
    }

    /// What iOS reads from a note: the capture, the audio, the transcript and an imported document's state.
    @Test func theFactsOfANote() {
        let active = UUID()
        var live = Note(id: active, title: "Live"); live.audio = .live
        #expect(RowFacts(live, jobState: nil, activeNoteID: active).audioKind == .liveCapture)
        #expect(RowFacts(live, jobState: nil, activeNoteID: active).isActiveCapture)

        let plain = Note(title: "Plain")
        #expect(RowFacts(plain, jobState: nil, activeNoteID: nil) == RowFacts(audioKind: .plain))

        var transcribed = Note(title: "Transcribed")
        transcribed.transcript = [TranscriptSegment(text: "Hello.", start: 0, end: 1)]
        #expect(RowFacts(transcribed, jobState: .queued, activeNoteID: nil)
            == RowFacts(audioKind: .document, documentState: .ok, jobState: .queued))

        var noSpeech = Note(title: "Silence"); noSpeech.status = .ready
        #expect(RowStatus.of(RowFacts(noSpeech, jobState: nil, activeNoteID: nil)) == .transcribed)

        var imported = transcribed; imported.document = DocumentInfo(state: .unknownFormat)
        #expect(RowStatus.of(RowFacts(imported, jobState: nil, activeNoteID: nil)) == .newerFormat)
        imported.document = DocumentInfo(state: .plainAudio)
        #expect(RowStatus.of(RowFacts(imported, jobState: nil, activeNoteID: nil)) == .transcribed, "transcribed here since")

        var unplayable = transcribed; unplayable.audio = .unplayable(.unsupportedFormat)
        #expect(RowStatus.of(RowFacts(unplayable, jobState: nil, activeNoteID: nil)) == .unplayable)
    }
}
