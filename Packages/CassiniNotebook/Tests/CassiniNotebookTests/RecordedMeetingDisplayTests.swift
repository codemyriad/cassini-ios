import Foundation
import Testing
@testable import CassiniNotebook

/// D95: display facts never promote the document's seal/import/sort timestamp to the meeting time.
struct RecordedMeetingDisplayTests {
    private let sealed = Date(timeIntervalSince1970: 1_794_211_740)
    private let recorded = Date(timeIntervalSince1970: 1_794_211_200)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func rowsAndHeaderCarryTheRecordedInstantInsteadOfSealTime() {
        var note = Note(title: "Planning meeting", createdAt: sealed)
        note.meetingTime = .instant(recorded)
        note.duration = 240
        let rows = LibraryMapping.sections(LibraryIndex([note]).entries, context: RowContext(), now: recorded,
                                           calendar: calendar)
        #expect(rows.count == 1)
        #expect(rows[0].key == .today)
        #expect(rows[0].rows[0].meetingTime == .instant(recorded))
        let subtitle = NoteSubtitle.of(note, mode: .audioOnly, now: recorded, calendar: calendar)
        #expect(subtitle?.meetingTime == .instant(recorded))
        #expect(subtitle?.duration == 240)
        let facts = DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil, speechModels: [:])
        #expect(facts.meetingTime == .instant(recorded))
    }

    @Test func unknownAndLocalTimesDoNotAcquireTheSortDateAndGroupByWrittenDay() {
        var unknown = Note(title: "Undated meeting", createdAt: sealed)
        unknown.meetingTime = .unknown
        var known = Note(title: "Dated meeting", createdAt: recorded)
        known.meetingTime = .instant(recorded)
        var local = Note(title: "Local meeting", createdAt: recorded.addingTimeInterval(-86_400))
        local.meetingTime = .local("2026-11-08T09:15:00")
        let sections = LibraryMapping.sections(LibraryIndex([unknown, known, local]).entries,
                                               context: RowContext(), now: recorded, calendar: calendar)
        #expect(sections.count == 3)
        #expect(sections[2].key == .undated)
        #expect(sections[0].key == .today)
        #expect(sections[1].key == DayGroups.key(CalendarDay(year: 2026, month: 11, day: 8), now: recorded, calendar: calendar))
        #expect(sections[1].rows[0].meetingTime == .local("2026-11-08T09:15:00"))
        #expect(Set(sections.map(\.id)).count == sections.count)
        for note in [unknown, local] {
            let subtitle = NoteSubtitle.of(note, mode: .audioOnly, now: recorded, calendar: calendar)
            let expectedDay = note.meetingTime.day(in: calendar).map { DayGroups.key($0, now: recorded, calendar: calendar) } ?? .undated
            #expect(subtitle?.day == expectedDay)
            #expect(subtitle?.meetingTime == note.meetingTime)
            #expect(DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil, speechModels: [:]).meetingTime == note.meetingTime)
        }
    }
}
