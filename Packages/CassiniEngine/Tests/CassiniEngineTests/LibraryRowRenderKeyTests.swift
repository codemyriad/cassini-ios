import Foundation
import Testing
import CassiniNotebook

struct LibraryRowRenderKeyTests {
    private func liveRow() -> LibraryRow {
        var note = Note(title: "Live meeting", createdAt: Date(timeIntervalSince1970: 0))
        note.audio = .live
        note.status = .recording
        return LibraryMapping.row(LibraryIndex([note]).entries[0],
                                  context: RowContext(activeNoteID: note.id, recordingElapsed: 1))
    }

    @Test func liveTicksKeepTheButtonIdentityWhileItsPresentationAdvances() {
        let initial = liveRow()
        for elapsed in [2.0, 3, 59, 60, 3_600] {
            var tick = initial
            tick.duration = elapsed
            #expect(tick != initial, "The text still receives the new duration")
            #expect(tick.renderKey == initial.renderKey, "A tick must preserve taps and open menus")
            #expect(Set([initial.renderKey, tick.renderKey]).count == 1)
        }
    }

    @Test func nonTickPresentationChangesReplaceEvenAnActiveRow() {
        let initial = liveRow()
        let changes: [(String, (inout LibraryRow) -> Void)] = [
            ("note identity", { $0.id = UUID() }),
            ("title", { $0.title = "Renamed" }),
            ("title highlights", { $0.titleRanges = [0..<4] }),
            ("creation date", { $0.createdAt = $0.createdAt.addingTimeInterval(1) }),
            ("meeting time", { $0.meetingTime = .instant($0.createdAt.addingTimeInterval(60)) }),
            ("search day", { $0.day = .today }),
            ("status", { $0.status = .queued }),
            ("excerpt", { $0.preview = Highlighted("Found words", ranges: [0..<5]) }),
            ("running highlight", { $0.highlighted.toggle() }),
            ("recording state", { $0.isRecording = false }),
            ("star", { $0.isFavorite.toggle() }),
            ("bookmarks", { $0.bookmarkCount += 1 }),
            ("saving capture", { $0.isSavingCapture = true }),
            ("import provenance", { $0.provenance = .importedOtherDevice }),
        ]
        for (field, change) in changes {
            var changed = initial
            change(&changed)
            #expect(changed.renderKey != initial.renderKey, "Refresh \(field) immediately")
        }
    }

    @Test func stopAndEverySavedPresentationChangeReplaceTheRetainedRow() {
        let active = liveRow()
        var saved = active
        saved.isRecording = false
        let states: [LibraryRow.Status] = [.audioOnly, .queued, .transcribing,
                                          .transcribed(speakers: 0, hasWords: false),
                                          .transcribed(speakers: 1, hasWords: true),
                                          .transcribed(speakers: 2, hasWords: true)]
        var keys = Set<LibraryRow.RenderKey>()
        for status in states {
            saved.duration = active.duration
            saved.status = status
            #expect(saved.renderKey != active.renderKey, "Stop must replace Recording even at the same duration")
            #expect(keys.insert(saved.renderKey).inserted, "Each saved status/speaker count refreshes the row")
            let previous = saved.renderKey
            saved.duration += 1
            #expect(saved.renderKey != previous, "Saved duration changes must never be ignored")
        }
    }
}
