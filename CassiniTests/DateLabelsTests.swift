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

    func testDateAndClockStayInTheSameExplicitZoneAcrossMidnight() throws {
        let cases: [(TimeZone, String, String, String)] = [
            (try XCTUnwrap(TimeZone(secondsFromGMT: 20_700)), "2026-01-01T00:15:00Z", "1 Jan, 6:00 AM", "6:00 AM"),
            (try XCTUnwrap(TimeZone(secondsFromGMT: -12_600)), "2026-01-01T00:15:00Z", "31 Dec, 8:45 PM", "8:45 PM"),
            (try XCTUnwrap(TimeZone(secondsFromGMT: 50_400)), "2025-12-31T12:15:00Z", "1 Jan, 2:15 AM", "2:15 AM"),
            (try XCTUnwrap(TimeZone(identifier: "Etc/GMT-14")), "2025-12-31T12:15:00Z", "1 Jan, 2:15 AM", "2:15 AM"),
            (try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12")), "2026-01-01T00:15:00Z", "31 Dec, 12:15 PM", "12:15 PM"),
            (try XCTUnwrap(TimeZone(identifier: "EST5EDT")), "2026-01-01T00:15:00Z", "31 Dec, 7:15 PM", "7:15 PM"),
            (try XCTUnwrap(TimeZone(identifier: "EST5EDT")), "2026-07-01T00:15:00Z", "30 Jun, 8:15 PM", "8:15 PM")
        ]
        let globalZone = TimeZone.current.identifier
        let globalLocale = Locale.current.identifier
        for (zone, timestamp, expected, clock) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US")
            calendar.timeZone = zone
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
            let labels = DateLabels(calendar: calendar)
            XCTAssertEqual(plainSpaces(labels.time(date)), clock, zone.identifier)
            XCTAssertEqual(plainSpaces(labels.shortDateTime(date, now: date)), expected, zone.identifier)
        }
        XCTAssertEqual(TimeZone.current.identifier, globalZone)
        XCTAssertEqual(Locale.current.identifier, globalLocale)
    }

    func testUndatedSectionHasTheSharedNonblankHeadingInAllSixLanguages() throws {
        let cases = [("en", "Date unknown"), ("it", "Data sconosciuta"), ("fr", "Date inconnue"),
                     ("es", "Fecha desconocida"), ("pt-BR", "Data desconhecida"), ("pt-PT", "Data desconhecida")]
        for (language, expected) in cases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let heading = DateLabels.unknownDate(bundle: bundle)
            XCTAssertEqual(heading, expected, language)
            XCTAssertFalse(heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "The Library's accessibility heading must never be blank")
        }
        XCTAssertEqual(DateLabels(calendar: calendar).day(.undated), "Date unknown",
                       "The actual day-header path uses the shared heading")
    }

    @MainActor func testRecordingAndTranscribingSpeakTheVisibleBadgeText() throws {
        var note = Note(title: "English meeting", createdAt: now)
        note.duration = 768
        note.meetingTime = .unknown
        var row = try XCTUnwrap(LibraryMapping.sections(LibraryIndex([note]).entries, context: RowContext(),
                                                       now: now, calendar: calendar).first?.rows.first)
        let format = LibraryFormat(calendar: calendar)
        for (status, spoken) in [(LibraryRow.Status.recording, "recording 12:48"), (.transcribing, "transcribing…")] {
            row.status = status
            row.isSavingCapture = false
            let label = format.rowLabel(row, day: .undated)
            XCTAssertEqual(label, "English meeting, \(format.spokenDuration(768)), \(spoken)")
            XCTAssertEqual(label.contains("12:48"), status == .recording)
        }
    }

    @MainActor func testCaptureSavingUsesTheExplicitFormatLocaleForItsSpokenStatus() throws {
        var note = Note(title: "English meeting", createdAt: now)
        note.duration = 768
        note.meetingTime = .unknown
        var row = try XCTUnwrap(LibraryMapping.sections(LibraryIndex([note]).entries, context: RowContext(),
                                                       now: now, calendar: calendar).first?.rows.first)
        row.status = .recording
        row.isSavingCapture = true
        let cases = [("en_US", "saving…"), ("it_IT", "salvataggio…"), ("fr_FR", "sauvegarde…"),
                     ("es_ES", "guardando…"), ("pt_BR", "salvando…"), ("pt_PT", "a guardar…")]
        for (locale, status) in cases {
            var local = calendar
            local.locale = Locale(identifier: locale)
            let format = LibraryFormat(calendar: local)
            XCTAssertEqual(format.rowLabel(row, day: .undated), "English meeting, \(format.spokenDuration(768)), \(status)", locale)
        }
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
