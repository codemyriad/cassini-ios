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

    public static func readUserStartedAt(_ document: CassiniDocument) -> String? {
        guard PortableTranscript.readableStates.contains(document.state),
              let xMeeting = document.manifest?["x"]?.object?["codemyriad.io"]?.object?["meeting"]?.object,
              xMeeting["startedAtSource"]?.string == "user",
              let startedAt = xMeeting["startedAt"]?.string,
              CassiniDocument.isValidStartedAt(startedAt) else { return nil }
        return startedAt
    }

    public static func read(_ document: CassiniDocument) -> MeetingTime {
        // A DATE tag alone cannot restore metadata that failed verification or names an unknown format.
        guard PortableTranscript.readableStates.contains(document.state),
              let meeting = document.manifest?["meeting"]?.object else { return .unknown }
        // D112 (L-87): a date the person set wins over everything, including legacy import-time markers.
        if let userStartedAt = readUserStartedAt(document), let date = parse(userStartedAt) {
            return .instant(date)
        }
        let isImportTimePrefix = document.manifest?["x"]?.object?["codemyriad.io"]?.object?["namePrefixSource"]?.string == "import-time"
        if !isImportTimePrefix,
           let text = meeting["startedAt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           CassiniDocument.isValidStartedAt(text), let date = parse(text) {
            return .instant(date)
        }
        if let text = meeting["recordedAtUtc"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasSuffix("Z"), let date = parse(text) {
            return .instant(date)
        }
        if isImportTimePrefix {
            return .unknown
        }
        let created = meeting["createdAtUtc"]?.string.flatMap(parse)
        // DATE must explicitly carry a zone (never -00:00); an offset-less label cannot establish an instant.
        if let comment = document.comments.first(where: { $0.split(separator: "=", maxSplits: 1).first?.uppercased() == "DATE" }),
           let equal = comment.firstIndex(of: "=") {
            let text = String(comment[comment.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.hasSuffix("-00:00"), let date = parse(text), date != created { return .instant(date) }
        }
        if let text = meeting["recordedAtLocal"]?.string, !text.isEmpty { return .local(text) }
        return .unknown
    }

    static func parse(_ text: String) -> Date? { CassiniDocument.parseInstant(text) }
}
