import Foundation
import Testing
import CassiniNotebook

/// Zones whose DST change skips midnight, so a local day can start at 01:00: every bound is still the real start of
/// its own local day, written as an explicit instant rather than recomputed with calendar arithmetic.
struct SearchDateMidnightDSTTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let zone: String, now: String, today: String, week: String, month: String, end: String
        var testDescription: String { "\(zone) at \(now)" }
    }

    static let cases = [
        // The transition day itself: today begins at 01:00, tomorrow and the earlier days at 00:00.
        Case(zone: "America/Santiago", now: "2026-09-06T12:00:00-03:00", today: "2026-09-06T01:00:00-03:00",
             week: "2026-08-31T00:00:00-04:00", month: "2026-08-08T00:00:00-04:00", end: "2026-09-07T00:00:00-03:00"),
        // The day after: the ranges reach back across the 01:00 day.
        Case(zone: "America/Santiago", now: "2026-09-07T12:00:00-03:00", today: "2026-09-07T00:00:00-03:00",
             week: "2026-09-01T00:00:00-04:00", month: "2026-08-09T00:00:00-04:00", end: "2026-09-08T00:00:00-03:00"),
        Case(zone: "America/Havana", now: "2026-03-08T12:00:00-04:00", today: "2026-03-08T01:00:00-04:00",
             week: "2026-03-02T00:00:00-05:00", month: "2026-02-07T00:00:00-05:00", end: "2026-03-09T00:00:00-04:00"),
    ]

    @Test(arguments: cases)
    func boundsAreEachLocalDaysRealStart(_ value: Case) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: value.zone))
        let parse = ISO8601DateFormatter()
        let now = try #require(parse.date(from: value.now))
        let end = try #require(parse.date(from: value.end))
        for (filter, start) in [(SearchDate.today, value.today), (.week, value.week), (.month, value.month)] {
            let interval = try #require(filter.interval(now: now, calendar: calendar))
            #expect(interval.start == parse.date(from: start), "\(filter) starts at its first day's start")
            #expect(interval.end == end, "\(filter) ends at tomorrow's start, not an hour into tomorrow")
        }
    }
}
