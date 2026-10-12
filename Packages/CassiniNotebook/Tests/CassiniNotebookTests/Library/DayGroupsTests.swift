import Foundation
import Testing
@testable import CassiniNotebook

/// Android `DayGroupsTest`.
struct DayGroupsTests {
    private let rome = DayGroupsTests.calendar("Europe/Rome")

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026, withYear: Bool = false) -> DayKey {
        .date(CalendarDay(year: year, month: month, day: day), withYear: withYear)
    }

    /// "2026-10-09T10:02" (seconds and milliseconds optional) as local time in `calendar`'s zone.
    private func at(_ text: String, _ calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? rome
        let parts = text.split(whereSeparator: { "-T:.".contains($0) }).map { Int($0)! }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])
        components.second = parts.count > 5 ? parts[5] : 0
        components.nanosecond = parts.count > 6 ? parts[6] * 1_000_000 : 0
        return calendar.date(from: components)!
    }

    private func key(_ created: String, _ now: String) -> DayKey {
        DayGroups.key(at(created), now: at(now), calendar: rome)
    }

    // ports: DayGroupsTest#todayYesterdayThisYearOtherYear
    @Test func todayYesterdayThisYearOtherYear() {
        #expect(key("2026-10-09T00:00", "2026-10-09T23:59:59") == .today)
        #expect(key("2026-10-08T10:02", "2026-10-09T15:00") == .yesterday)
        #expect(key("2026-10-05T08:14", "2026-10-09T15:00") == day(10, 5))
        #expect(key("2025-10-09T08:14", "2026-10-09T15:00") == day(10, 9, 2025, withYear: true))
    }

    // ports: DayGroupsTest#acrossMidnight
    @Test func acrossMidnight() {
        #expect(key("2026-10-08T23:59:59.999", "2026-10-09T00:00") == .yesterday)
        #expect(key("2026-10-09T00:00", "2026-10-09T00:00:00.001") == .today)
        #expect(key("2026-10-07T23:59", "2026-10-09T00:01") == day(10, 7))
    }

    // ports: DayGroupsTest#acrossTheYearBoundary
    @Test func acrossTheYearBoundary() {
        #expect(key("2026-12-31T23:50", "2027-01-01T00:05") == .yesterday)
        #expect(key("2026-12-30T12:00", "2027-01-01T00:05") == day(12, 30, withYear: true))
        #expect(key("2027-01-01T09:00", "2027-01-03T09:00") == day(1, 1, 2027))
    }

    // ports: DayGroupsTest#romeDstChanges
    @Test func romeDstChanges() {
        // 29 Mar 2026: 02:00 CET jumps to 03:00 CEST (a 23-hour day).
        #expect(key("2026-03-29T00:30", "2026-03-29T23:59") == .today)
        #expect(key("2026-03-28T23:30", "2026-03-29T00:10") == .yesterday)
        #expect(key("2026-03-28T00:10", "2026-03-29T23:50") == .yesterday)
        // 25 Oct 2026: 03:00 CEST falls back to 02:00 CET (a 25-hour day). Both 02:30 instants are the same day.
        let early = Date(timeIntervalSince1970: 1_792_888_200) // 00:30 UTC = 02:30 CEST
        let late = Date(timeIntervalSince1970: 1_792_891_800) // 01:30 UTC = 02:30 CET
        #expect(DayGroups.key(early, now: late, calendar: rome) == .today)
        #expect(key("2026-10-24T00:05", "2026-10-25T23:55") == .yesterday)
    }

    // ports: DayGroupsTest#theZoneDecidesTheDay
    @Test func theZoneDecidesTheDay() {
        // 23:30 UTC on 8 Oct is already 9 Oct in Rome.
        let utc = Self.calendar("UTC")
        let created = at("2026-10-08T23:30", utc), now = at("2026-10-09T08:00", utc)
        #expect(DayGroups.key(created, now: now, calendar: utc) == .yesterday)
        #expect(DayGroups.key(created, now: now, calendar: rome) == .today)
    }

    // ports: DayGroupsTest#groupsKeepOrder
    @Test func groupsKeepOrder() {
        let now = at("2026-10-09T15:00")
        let notes = ["2026-10-09T10:02", "2026-10-09T08:40", "2026-10-08T15:10", "2026-10-08T11:00", "2026-10-05T08:14"]
            .map { at($0) }
        let groups = DayGroups.group(notes, now: now, calendar: rome) { $0 }
        #expect(groups.map(\.key) == [.today, .yesterday, day(10, 5)])
        #expect(groups.map(\.items) == [Array(notes[0..<2]), Array(notes[2..<4]), Array(notes[4...])])
        #expect(DayGroups.group([Date](), now: now, calendar: rome) { $0 }.isEmpty)
    }
}
