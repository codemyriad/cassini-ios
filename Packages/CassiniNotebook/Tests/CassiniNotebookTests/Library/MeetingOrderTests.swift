import Foundation
import Testing
@testable import CassiniNotebook

struct MeetingOrderTests {
    private func instant(_ text: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: text)) }
    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }
    private func note(_ title: String, time: MeetingTime, sealed: String) throws -> Note {
        var note = Note(title: title, createdAt: try instant(sealed))
        note.meetingTime = time
        return note
    }

    @Test func localSectionsRowsAndSearchFollowWrittenMeetingsRatherThanTheirSealOrder() throws {
        let calendar = calendar(try #require(TimeZone(secondsFromGMT: 0)))
        let now = try instant("2026-11-11T12:00:00Z")
        let oldest = try note("English November eight", time: .local("2026-11-08T23:00:00"), sealed: "2026-11-14T12:00:00Z")
        let morning = try note("English morning", time: .local("2026-11-10T09:00:00"), sealed: "2026-11-13T12:00:00Z")
        let noon = try note("English noon", time: .local("2026-11-10T12:30:00"), sealed: "2026-11-12T12:00:00Z")
        let evening = try note("English evening", time: .local("2026-11-10T18:00:00"), sealed: "2026-11-11T12:00:00Z")
        var index = LibraryIndex([oldest, morning, noon, evening])
        let expected = [evening.id, noon.id, morning.id, oldest.id]
        let sections = LibraryMapping.sections(index.entries, context: RowContext(), now: now, calendar: calendar)
        #expect(sections.map(\.key) == [.yesterday, .date(CalendarDay(year: 2026, month: 11, day: 8), withYear: false)])
        #expect(sections.map { $0.rows.map(\.id) } == [[evening.id, noon.id, morning.id], [oldest.id]])
        let results = LibraryMapping.results(index.search(SearchQuery("English")), context: RowContext(), now: now, calendar: calendar)
        #expect(results.map(\.id) == expected)
        #expect(results.allSatisfy { !$0.titleRanges.isEmpty }, "Reordering keeps search highlights attached to their own note")
        #expect(results.map(\.meetingTime) == [evening, noon, morning, oldest].map(\.meetingTime))
    }

    @Test func mixedTimesResolveInstantDaysInTheExplicitOddOffsetZoneAndKeepLocalClockComponents() throws {
        let zones: [(Int, String, String, String)] = [
            (20_700, "2026-11-09T20:00:00Z", "2026-11-10T01:45:00", "2026-11-10T01:30:00"),
            (-12_600, "2026-11-10T01:45:00Z", "2026-11-09T22:15:00", "2026-11-09T22:00:00")
        ]
        for (offset, utc, sameWallClock, earlierLocalClock) in zones {
            let calendar = calendar(try #require(TimeZone(secondsFromGMT: offset)))
            let dated = try note("English instant", time: .instant(instant(utc)), sealed: "2026-11-01T12:00:00Z")
            let local = try note("English local", time: .local(earlierLocalClock), sealed: "2026-11-30T12:00:00Z")
            let exact = try note("English same clock", time: .local(sameWallClock), sealed: "2026-11-29T12:00:00Z")
            let entries = LibraryIndex([local, dated, exact]).entries
            let sections = LibraryMapping.sections(entries, context: RowContext(), now: try instant("2026-11-11T12:00:00Z"), calendar: calendar)
            #expect(sections.count == 1)
            #expect(sections[0].rows.map(\.id) == [dated.id, exact.id, local.id])
            #expect(local.meetingTime.instant == nil)
            #expect(exact.meetingTime.instant == nil)
            #expect(sections[0].rows.last?.meetingTime == .local(earlierLocalClock))
        }
    }

    @Test func nonexistentDSTClockIsNotNormalizedAndRepeatedClocksHaveDeterministicDisplayOrder() throws {
        let calendar = calendar(try #require(TimeZone(identifier: "America/New_York")))
        let before = try note("English before gap", time: .instant(instant("2026-03-08T06:45:00Z")), sealed: "2026-11-01T12:00:00Z")
        let gap = try note("English written gap", time: .local("2026-03-08T02:30:00"), sealed: "2026-11-03T12:00:00Z")
        let after = try note("English after gap", time: .instant(instant("2026-03-08T07:15:00Z")), sealed: "2026-11-02T12:00:00Z")
        #expect(MeetingOrder.sorted([gap, before, after], calendar: calendar, note: { $0 }).map(\.id) == [after.id, gap.id, before.id])
        #expect(gap.meetingTime == .local("2026-03-08T02:30:00"))
        #expect(gap.meetingTime.instant == nil)

        let firstFold = try note("English first fold", time: .instant(instant("2026-11-01T05:50:00Z")), sealed: "2026-11-01T12:00:00Z")
        let secondFold = try note("English second fold", time: .instant(instant("2026-11-01T06:10:00Z")), sealed: "2026-11-02T12:00:00Z")
        let ambiguous = try note("English written fold", time: .local("2026-11-01T01:30:00"), sealed: "2026-11-03T12:00:00Z")
        // No zone or fold is assigned to the local label. One transitive wall-clock order is used for every row.
        #expect(MeetingOrder.sorted([ambiguous, secondFold, firstFold], calendar: calendar, note: { $0 }).map(\.id)
            == [firstFold.id, ambiguous.id, secondFold.id])
        let equalInstant = try note("English equal fold", time: .instant(instant("2026-11-01T06:30:00Z")), sealed: "2026-11-05T12:00:00Z")
        #expect(MeetingOrder.sorted([ambiguous, equalInstant], calendar: calendar, note: { $0 }).map(\.id) == [equalInstant.id, ambiguous.id])
        #expect(MeetingOrder.sorted([equalInstant, ambiguous], calendar: calendar, note: { $0 }).map(\.id) == [equalInstant.id, ambiguous.id])
    }

    @Test func unknownTimesFollowEveryKnownTimeAndUseCreationFallbackOnlyWithinUndated() throws {
        let calendar = calendar(try #require(TimeZone(secondsFromGMT: 0)))
        let known = try note("English known", time: .local("2026-11-10T12:00:00"), sealed: "2099-01-01T00:00:00Z")
        let unknown = try note("English unknown", time: .unknown, sealed: "2026-11-11T12:00:00Z")
        let malformed = try note("English malformed", time: .local("not a recording date"), sealed: "2199-01-01T00:00:00Z")
        let sorted = MeetingOrder.sorted([malformed, known, unknown], calendar: calendar, note: { $0 })
        #expect(sorted.map(\.id) == [known.id, malformed.id, unknown.id])
        #expect(sorted.map(\.meetingTime) == [.local("2026-11-10T12:00:00"), .local("not a recording date"), .unknown])
        #expect(malformed.meetingTime.day(in: calendar) == nil)
    }
    @Test func equalCalendarClocksUseInstantThenIdentityAndUnknownSearchHitsStayLast() throws {
        let calendar = calendar(try #require(TimeZone(identifier: "America/New_York")))
        let first = try note("English first clock", time: .instant(instant("2026-11-01T05:30:00Z")), sealed: "2026-11-12T12:00:00Z")
        let second = try note("English second clock", time: .instant(instant("2026-11-01T06:30:00Z")), sealed: "2026-11-11T12:00:00Z")
        let floating = try note("English floating clock", time: .local("2026-11-01T01:30:00"), sealed: "2026-11-30T12:00:00Z")
        var olderUnknown = try note("English unknown earlier", time: .unknown, sealed: "2026-11-29T12:00:00Z")
        var equalUnknown = try note("English unknown equal", time: .unknown, sealed: "2026-11-29T12:00:00Z")
        let recentUnknown = try note("English unknown recent", time: .unknown, sealed: "2026-11-30T12:00:00Z")
        olderUnknown.id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        equalUnknown.id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let input = [equalUnknown, floating, first, recentUnknown, olderUnknown, second]
        let expected = [second.id, first.id, floating.id, recentUnknown.id, olderUnknown.id, equalUnknown.id]
        #expect(MeetingOrder.sorted(input, calendar: calendar, note: { $0 }).map(\.id) == expected)
        #expect(MeetingOrder.sorted(Array(input.reversed()), calendar: calendar, note: { $0 }).map(\.id) == expected)
        var index = LibraryIndex(input)
        let rows = LibraryMapping.results(index.search(SearchQuery("English")), context: RowContext(),
                                          now: try instant("2026-11-30T12:00:00Z"), calendar: calendar)
        #expect(rows.map(\.id) == expected)
        let sections = LibraryMapping.sections(index.entries, context: RowContext(),
                                               now: try instant("2026-11-30T12:00:00Z"), calendar: calendar)
        #expect(sections.last?.key == .undated)
        #expect(sections.last?.rows.map(\.id) == [recentUnknown.id, olderUnknown.id, equalUnknown.id])
    }

}
