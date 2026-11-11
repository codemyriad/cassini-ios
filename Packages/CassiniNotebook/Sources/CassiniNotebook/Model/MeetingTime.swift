import Foundation
import CassiniCore

/// The meeting start, distinct from file creation/sealing and the catalogue sorting fallback (D95).
/// A wall-clock label without a zone is displayed exactly as stored, never converted to an instant.
public enum MeetingTime: Hashable, Codable, Sendable {
    case instant(Date)
    case local(String)
    case unknown

    public var instant: Date? { if case .instant(let date) = self { date } else { nil } }
    public var localText: String? { if case .local(let text) = self { text } else { nil } }

    /// A label contributes its written day without ever being assigned a viewer-zone instant.
    public func day(in calendar: Calendar) -> CalendarDay? {
        switch self {
        case .instant(let date):
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return CalendarDay(year: year, month: month, day: day)
        case .local(let text):
            guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#,
                             options: .regularExpression) != nil else { return nil }
            let numbers = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
            guard numbers.count == 6 else { return nil }
            let y = numbers[0], m = numbers[1], d = numbers[2]
            guard y >= 1, (1...12).contains(m), (0...23).contains(numbers[3]),
                  (0...59).contains(numbers[4]), (0...59).contains(numbers[5]) else { return nil }
            let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...days[m - 1]).contains(d) else { return nil }
            return CalendarDay(year: y, month: m, day: d)
        case .unknown: return nil
        }
    }

    public func isWithin(_ range: DateInterval, calendar: Calendar) -> Bool {
        if let instant { return instant >= range.start && instant < range.end }
        guard let day = day(in: calendar),
              let lower = MeetingTime.instant(range.start).day(in: calendar),
              let upper = MeetingTime.instant(range.end).day(in: calendar) else { return false }
        func key(_ day: CalendarDay) -> Int { day.year * 10_000 + day.month * 100 + day.day }
        return key(day) >= key(lower) && key(day) < key(upper)
    }

    public static func read(_ document: CassiniDocument) -> MeetingTime {
        let meeting = document.manifest?["meeting"]?.object
        if let text = meeting?["recordedAtUtc"]?.string, text.hasSuffix("Z"), let date = parse(text) {
            return .instant(date)
        }
        let created = meeting?["createdAtUtc"]?.string.flatMap(parse)
        // DATE must explicitly carry a zone; an offset-less label cannot establish an instant.
        if let comment = document.comments.first(where: { $0.split(separator: "=", maxSplits: 1).first?.uppercased() == "DATE" }),
           let equal = comment.firstIndex(of: "=") {
            let text = String(comment[comment.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.range(of: #"(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil,
               let date = parse(text), date != created { return .instant(date) }
        }
        if let text = meeting?["recordedAtLocal"]?.string, !text.isEmpty { return .local(text) }
        return .unknown
    }

    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
