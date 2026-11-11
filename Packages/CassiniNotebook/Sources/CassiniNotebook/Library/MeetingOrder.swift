import Foundation

/// D95 display ordering: compare the calendar day and clock the user sees, newest first.
/// Local labels contribute their written components, never a timezone-resolved instant. Unknown meeting times
/// alone use catalogue creation as a sorting fallback. Equal display clocks retain their incoming order.
/// Around a DST fold, a local label cannot say which occurrence it means. Use this one transitive display-clock
/// ordering for all known times; do not switch to a contradictory UTC comparator for selected pairs.
public enum MeetingOrder {
    public static func sorted<Element>(_ values: [Element], calendar: Calendar,
                                       note: (Element) -> Note) -> [Element] {
        // Calendar decomposition is paid once per note, rather than for every sort comparison.
        let keyed = values.enumerated().map { (offset: $0.offset, value: $0.element, key: key(note($0.element), calendar)) }
        return keyed.sorted { lhs, rhs in
            switch (lhs.key, rhs.key) {
            case (.some(let a), .some(let b)):
                if a != b { return b.lexicographicallyPrecedes(a) }
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
            return lhs.offset < rhs.offset
        }.map(\.value)
    }

    private static func key(_ note: Note, _ calendar: Calendar) -> [Int]? {
        switch note.meetingTime {
        case .instant(let instant): return components(instant, calendar)
        case .local(let text):
            guard let day = note.meetingTime.day(in: calendar) else { return nil }
            let clock = text.split(separator: "T", maxSplits: 1).last?.split(separator: ":").compactMap { Int($0) } ?? []
            guard clock.count == 3 else { return nil }
            return [day.year, day.month, day.day, clock[0], clock[1], clock[2], 0]
        case .unknown: return components(note.createdAt, calendar)
        }
    }

    private static func components(_ date: Date, _ calendar: Calendar) -> [Int]? {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return nil }
        return [year, month, day, hour, minute, second, parts.nanosecond ?? 0]
    }
}
