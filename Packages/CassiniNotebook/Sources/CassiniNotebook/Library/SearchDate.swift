import Foundation

/// D14: local calendar days, including today; never a rolling count of 24-hour periods.
public enum SearchDate: CaseIterable, Hashable, Sendable {
    case any, today, week, month

    public func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let days: Int
        switch self {
        case .any: return nil
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - days, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return DateInterval(start: start, end: end)
    }
}
