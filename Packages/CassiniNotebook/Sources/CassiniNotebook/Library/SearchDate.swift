import Foundation

/// D14: local calendar days, including today; never a rolling count of 24-hour periods.
public enum SearchDate: CaseIterable, Hashable, Sendable {
    case any, today, week, month, year

    public func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let days: Int
        switch self {
        case .any: return nil
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        case .year:
            guard let start = calendar.dateInterval(of: .year, for: now)?.start,
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return DateInterval(start: calendar.startOfDay(for: start), end: calendar.startOfDay(for: tomorrow))
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - days, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        // Some local days begin at 01:00 when DST skips midnight. Calendar day addition preserves that hour,
        // so normalize both destination days rather than extending tomorrow or trimming the range's first day.
        return DateInterval(start: calendar.startOfDay(for: start), end: calendar.startOfDay(for: end))
    }
}
