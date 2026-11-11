import Foundation
import Testing
import CassiniNotebook

struct SearchDateTests {
    @Test(arguments: ["2026-03-08T12:00:00-04:00", "2026-11-01T12:00:00-05:00", "2027-01-01T12:00:00-05:00"])
    func localCalendarBounds(_ timestamp: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(ISO8601DateFormatter().date(from: timestamp))
        let midnight = calendar.startOfDay(for: now)
        #expect(SearchDate.any.interval(now: now, calendar: calendar) == nil)
        for (filter, days) in [(SearchDate.today, 1), (.week, 7), (.month, 30)] {
            let interval = try #require(filter.interval(now: now, calendar: calendar))
            #expect(interval.start == calendar.date(byAdding: .day, value: 1 - days, to: midnight))
            #expect(interval.end == calendar.date(byAdding: .day, value: 1, to: midnight))
            #expect(calendar.component(.hour, from: interval.start) == 0)
        }
        let today = try #require(SearchDate.today.interval(now: now, calendar: calendar))
        if timestamp.hasPrefix("2026-03") { #expect(today.duration == 23 * 3600) }
        if timestamp.hasPrefix("2026-11") { #expect(today.duration == 25 * 3600) }
    }

    @Test func midnightDSTNormalizesBothBoundsToTheirOwnLocalDayStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        func instant(_ value: String) throws -> Date {
            try #require(ISO8601DateFormatter().date(from: value))
        }
        let now = try instant("2026-09-06T15:00:00Z")
        let end = try instant("2026-09-07T03:00:00Z")
        let expected: [(SearchDate, String)] = [
            (.today, "2026-09-06T04:00:00Z"),
            (.week, "2026-08-31T04:00:00Z"),
            (.month, "2026-08-08T04:00:00Z")
        ]
        #expect(calendar.component(.hour, from: calendar.startOfDay(for: now)) == 1,
                "Santiago skips midnight on this date; the actual day starts at 01:00")
        for (filter, beginning) in expected {
            let interval = try #require(filter.interval(now: now, calendar: calendar))
            let start = try instant(beginning)
            #expect(interval.start == start)
            #expect(interval.end == end)
            #expect(MeetingTime.instant(start).isWithin(interval, calendar: calendar))
            #expect(!MeetingTime.instant(start.addingTimeInterval(-1)).isWithin(interval, calendar: calendar))
            #expect(!MeetingTime.instant(end).isWithin(interval, calendar: calendar))
            #expect(!MeetingTime.instant(end.addingTimeInterval(1_800)).isWithin(interval, calendar: calendar),
                    "Tomorrow's first hour does not belong to this range")
        }
        let week = try #require(SearchDate.week.interval(now: now, calendar: calendar))
        let month = try #require(SearchDate.month.interval(now: now, calendar: calendar))
        #expect(MeetingTime.instant(try instant("2026-08-31T04:30:00Z")).isWithin(week, calendar: calendar))
        #expect(MeetingTime.instant(try instant("2026-08-08T04:30:00Z")).isWithin(month, calendar: calendar),
                "The range keeps its first local hour even though today began at 01:00")
    }

}
