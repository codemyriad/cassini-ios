import Foundation
import Testing
@testable import CassiniNotebook

struct RowBadgeTests {
    /// The real pinned catalog, not copied English labels or a second badge formatter.
    private func text() throws -> StatusBadges.Text {
        let root = try #require(Bundle.module.url(forResource: "status-badges", withExtension: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("strings/strings.json"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(catalog["entries"] as? [[String: Any]])
        let labels = Dictionary(uniqueKeysWithValues: entries.compactMap { item -> (String, String)? in
            guard let id = item["id"] as? String, let en = item["en"] as? String else { return nil }
            return (id, en)
        })
        return { labels[$0]! }
    }
    private func note(live: Bool = false) -> Note {
        var note = Note(title: "Community garden planning", createdAt: Date(timeIntervalSince1970: 1_799_000_000))
        note.audio = live ? .live : .plain
        note.status = live ? .recording : .audioOnly
        note.duration = 24
        return note
    }
    private func row(_ note: Note, _ context: RowContext) -> LibraryRow {
        LibraryMapping.row(LibraryIndex([note]).entries[0], context: context)
    }
    private func active(_ note: Note, elapsed: TimeInterval) -> RecordingState {
        .active(ActiveRecording(noteID: note.id, title: note.title, defaultTitle: note.title,
                                format: .pcm48kMono, elapsed: elapsed))
    }

    @Test func actualFinishingCaptureMapsItsLiveNoteToSavingAndNoOtherRow() throws {
        let note = note(live: true)
        let context = RowContext(processing: ProcessingState(), recording: .finishing(noteID: note.id))
        let actual = row(note, context)
        let text = try text()
        #expect(actual.status == .recording)
        #expect(context.isSavingCapture && actual.isSavingCapture)
        #expect(RowBadge.presentation(actual, text: text)
            == StatusBadges.meeting(.init(lifecycle: .saving), text: text))
        let other = row(self.note(live: true), context)
        #expect(!other.isSavingCapture && !other.isRecording)
        #expect(RowBadge.presentation(other, text: text) == nil)
        #expect(!RowContext().isSavingCapture)
        #expect(!RowContext(activeNoteID: note.id).isSavingCapture,
                "Existing context construction must not silently acquire Saving")
    }

    @Test func activeCaptureUsesLiveElapsedTimeRatherThanStoredDuration() throws {
        let note = note(live: true)
        let text = try text()
        for milliseconds in [Int64(0), 59_999, 303_000, 768_000, 3_600_000, 3_768_000] {
            let elapsed = Double(milliseconds) / 1_000
            let context = RowContext(processing: ProcessingState(), recording: active(note, elapsed: elapsed))
            let actual = row(note, context)
            #expect(actual.duration == elapsed)
            #expect(actual.isRecording && !actual.isSavingCapture)
            #expect(RowBadge.presentation(actual, text: text)
                == StatusBadges.meeting(.init(lifecycle: .recording, liveMs: milliseconds), text: text))
        }
    }

    @Test func localTranscriptionNeverInventsAnETAOrCaptureSavingFromItsPhase() throws {
        let note = note()
        let text = try text()
        // Local detail progress exposes a TimeLeft interval, not a persisted scalar etaMinutes.
        for phase in [ProcessingPhase.starting, .transcribing, .identifyingSpeakers, .saving] {
            let processing = ProcessingState(running: RunningJob(noteID: note.id, title: note.title, phase: phase))
            let actual = row(note, RowContext(processing: processing, recording: .idle))
            #expect(actual.status == .transcribing && !actual.isSavingCapture)
            #expect(RowBadge.presentation(actual, text: text)
                == StatusBadges.transcribing(etaMinutes: nil, text: text))
        }
    }

    @Test func everyProvisionalPhoneStatusLeavesItsLegacyPresentationUntouched() throws {
        var actual = row(note(), RowContext())
        let statuses: [LibraryRow.Status] = [.queued, .paused(atMs: 0), .paused(atMs: 760_000), .failed,
            .unplayable, .unreadable, .newerFormat, .transcribed(speakers: 2, hasWords: true),
            .transcribed(speakers: 0, hasWords: false), .audioOnly]
        let text = try text()
        for status in statuses {
            actual.status = status
            #expect(RowBadge.presentation(actual, text: text) == nil, "\(status) must retain the app's legacy label/applicability")
        }
    }

    @Test func invalidElapsedTimeCannotTrapOrBecomeAnInventedLiveClock() throws {
        let note = note(live: true)
        let text = try text()
        let zero = StatusBadges.meeting(.init(lifecycle: .recording, liveMs: 0), text: text)
        for elapsed in [-1.0, -Double.infinity, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            let actual = row(note, RowContext(processing: ProcessingState(), recording: active(note, elapsed: elapsed)))
            #expect(RowBadge.presentation(actual, text: text) == zero)
        }
    }
}
