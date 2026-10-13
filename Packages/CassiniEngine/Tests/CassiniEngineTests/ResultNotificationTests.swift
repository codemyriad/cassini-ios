import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// The notification each job outcome posts while Cassini is hidden.
@Suite struct ResultNotificationTests {
    private let id = UUID()

    private func announcing(_ outcome: JobOutcome, note: Note? = nil) -> ResultNotification? {
        ResultNotification.announcing(outcome, noteID: id, title: "At the start", note: note)
    }

    @Test func aSealedJobTellsTheNoteAsItIsNow() {
        var note = Note(title: "Renamed meanwhile"); note.duration = 90
        note.speakers = [NoteSpeaker(id: "s1", name: "Speaker 1"), NoteSpeaker(id: "s2", name: "Speaker 2")]
        let expected = ResultNotification(noteID: note.id, title: "Renamed meanwhile",
                                          kind: .transcribed(speakers: 2, duration: 90))
        #expect(announcing(.done, note: note) == expected)
        #expect(announcing(.adoptPending, note: note) == expected)
        #expect(announcing(.done) == nil, "the note is gone")
    }

    @Test func aFailureOrMissingConsentTellsTheTitleTheJobBeganWith() {
        #expect(announcing(.failed(.audio)) == ResultNotification(noteID: id, title: "At the start", kind: .failed(.audio)))
        #expect(announcing(.downloadFailed(DownloadFailure(error: .noConnection, part: .speech)))?.kind
            == .failed(.download(.noConnection)))
        #expect(announcing(.needsConsent(missingBytes: 1_000))?.kind == .readyToTranscribe)
    }

    @Test func aPauseOrCancelTellsNothing() {
        #expect(announcing(.paused(.user)) == nil)
        #expect(announcing(.paused(.system)) == nil)
        #expect(announcing(.cancelled) == nil)
    }
}
