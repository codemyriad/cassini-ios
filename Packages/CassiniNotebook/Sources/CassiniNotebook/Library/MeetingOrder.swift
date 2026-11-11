import Foundation

/// D95 display ordering: compare the calendar day and clock the user sees, newest first.
/// Local labels contribute their written components, never a timezone-resolved instant. Unknown meeting times
/// remain after known meeting times, ordered by catalogue creation and stable note identity.
/// Around a DST fold, a local label cannot say which occurrence it means. Use this one transitive display-clock
/// ordering for all known times; do not switch to a contradictory UTC comparator for selected pairs.
public enum MeetingOrder {
    public static func sorted<Element>(_ values: [Element], calendar: Calendar,
                                       note: (Element) -> Note) -> [Element] {
        // Calendar decomposition is paid once per note, rather than for every sort comparison.
        let keyed = values.enumerated().map { offset, value in
            let item = note(value)
            return (offset: offset, value: value, key: key(item, calendar), instant: item.meetingTime.instant,
                    fallback: item.createdAt, id: item.id.uuidString.lowercased())
        }
        return keyed.sorted { lhs, rhs in
            switch (lhs.key, rhs.key) {
            case (.some(let a), .some(let b)):
                if a != b { return b.lexicographicallyPrecedes(a) }
                // Android's tie order: resolved instant, then stable identity. Floating local labels stay unzoned.
                switch (lhs.instant, rhs.instant) {
                case (.some(let a), .some(let b)): if a != b { return a > b }
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                if lhs.fallback != rhs.fallback { return lhs.fallback > rhs.fallback }
            }
            if lhs.id != rhs.id { return lhs.id < rhs.id }
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
        case .unknown: return nil
        }
    }

    private static func components(_ date: Date, _ calendar: Calendar) -> [Int]? {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return nil }
        return [year, month, day, hour, minute, second, parts.nanosecond ?? 0]
    }
}
