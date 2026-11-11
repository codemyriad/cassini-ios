import Foundation

/// A calendar day, as the Library's day headers name it.
public struct CalendarDay: Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    /// The start of the day in `calendar`'s zone.
    public func start(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

/// The Library day header of a note: "Today", "Yesterday", or a date shown `withYear` when not in the current year.
public enum DayKey: Hashable, Sendable {
    case today
    case yesterday
    /// No meeting instant is known; local wall times stay as written on each row.
    case undated
    case date(CalendarDay, withYear: Bool)
}

/// Groups notes by the local calendar day of their creation time (features.md section 1).
public enum DayGroups {
    /// The day header of `date` seen at `now` in `calendar`'s zone. Calendar days, so a DST change never shifts a note.
    public static func key(_ date: Date, now: Date, calendar: Calendar) -> DayKey {
        let day = Self.day(date, calendar), today = Self.day(now, calendar)
        if day == today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           day == Self.day(yesterday, calendar) { return .yesterday }
        return .date(day, withYear: day.year != today.year)
    }

    /// Splits `items`, already ordered newest first, into runs of consecutive items with the same `DayKey`. The order
    /// inside and between groups is kept.
    public static func group<T>(_ items: [T], now: Date, calendar: Calendar, date: (T) -> Date) -> [(key: DayKey, items: [T])] {
        var groups: [(key: DayKey, items: [T])] = []
        for item in items {
            let key = key(date(item), now: now, calendar: calendar)
            if groups.last?.key == key { groups[groups.count - 1].items.append(item) } else { groups.append((key, [item])) }
        }
        return groups
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> CalendarDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }
}
