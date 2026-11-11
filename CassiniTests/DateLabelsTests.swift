import XCTest
import CassiniNotebook
@testable import Cassini

/// A note's date reads the same in the Library, on its screen, in Versions and in Recently Deleted: Android's
/// `Dates.dayLabel`, `shortDate` and `shortDateTime` forms, the year only for another year.
final class DateLabelsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Thursday 8 October 2026, 09:41 UTC, the UI tests' clock.
    private let now = Date(timeIntervalSince1970: 1_791_452_460)

    private func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // ports: FormatTest#dates (the Note screen's subtitle of an older note)
    @MainActor func testTheSubtitleOfAnOlderNoteNamesItsDayAsTheLibraryDoes() throws {
        var note = Note(title: "Walk", createdAt: now.addingTimeInterval(-3 * 86_400))
        note.duration = 24
        let older = try XCTUnwrap(NoteSubtitle.of(note, mode: .audioOnly, now: now, calendar: calendar))
        XCTAssertEqual(plainSpaces(NoteCopy.subtitle(older, calendar: calendar)), "Monday 5 Oct, 9:41 AM · 00:24")
        XCTAssertEqual(plainSpaces(NoteCopy.subtitle(try XCTUnwrap(NoteSubtitle.of(note, mode: .audioOnly,
                                                                                   now: note.createdAt, calendar: calendar)),
                                                     calendar: calendar)), "Today, 9:41 AM · 00:24")
        note.createdAt = now.addingTimeInterval(-400 * 86_400)
        note.meetingTime = .instant(note.createdAt)
        let lastYear = try XCTUnwrap(NoteSubtitle.of(note, mode: .audioOnly, now: now, calendar: calendar))
        XCTAssertEqual(plainSpaces(NoteCopy.subtitle(lastYear, calendar: calendar)), "3 Sep 2025, 9:41 AM · 00:24")
    }

    @MainActor func testUnknownAndLocalMeetingTimesNeverDisplayTheSealDate() throws {
        var note = Note(title: "Undated meeting", createdAt: now)
        note.duration = 24
        note.meetingTime = .unknown
        let unknown = try XCTUnwrap(NoteSubtitle.of(note, mode: .audioOnly, now: now, calendar: calendar))
        XCTAssertEqual(NoteCopy.subtitle(unknown, calendar: calendar), "00:24")
        let unknownRow = try XCTUnwrap(LibraryMapping.sections(LibraryIndex([note]).entries, context: RowContext(),
                                                             now: now, calendar: calendar).first?.rows.first)
        let format = LibraryFormat(calendar: calendar)
        XCTAssertNil(format.meetingTime(unknownRow))
        XCTAssertFalse(format.rowLabel(unknownRow, day: .undated).contains("9:41"))
        note.meetingTime = .local("2026-11-08T09:15:00")
        let local = try XCTUnwrap(NoteSubtitle.of(note, mode: .audioOnly, now: now, calendar: calendar))
        XCTAssertEqual(NoteCopy.subtitle(local, calendar: calendar), "2026-11-08T09:15:00 · 00:24")
        let localRow = try XCTUnwrap(LibraryMapping.sections(LibraryIndex([note]).entries, context: RowContext(),
                                                           now: now, calendar: calendar).first?.rows.first)
        XCTAssertEqual(format.meetingTime(localRow), "2026-11-08T09:15:00")
        XCTAssertTrue(format.rowLabel(localRow, day: .undated).contains("2026-11-08T09:15:00"))
    }

    func testRecentlyDeletedAndVersionsUseTheShortDate() {
        XCTAssertEqual(Locale.current.language.languageCode?.identifier, "en")
        XCTAssertEqual(Locale.current.region?.identifier, "US", "English copy tests use the scheme's pinned locale")
        let first = now.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(TrashCopy.deleted(TrashDay(first, now: now, calendar: calendar), calendar: calendar), "Deleted 1 Oct")
        let dates = DateLabels(calendar: calendar)
        XCTAssertEqual(plainSpaces(dates.shortDateTime(first, now: now)), "1 Oct, 9:41 AM")
        XCTAssertEqual(plainSpaces(SpeakersCopy.versionTranscribed(at: dates.shortDateTime(first, now: now), words: 4_812)),
                       "Transcribed 1 Oct, 9:41 AM · 4,812 words", "the count is grouped")
        XCTAssertEqual(SpeakersCopy.versionMerged(from: 1, at: "1 Oct, 9:41 AM"), "Speakers merged · from version 1 · 1 Oct, 9:41 AM")
        XCTAssertEqual(SpeakersCopy.wordCount(1), "1 word")
    }
}
