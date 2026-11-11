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
}
