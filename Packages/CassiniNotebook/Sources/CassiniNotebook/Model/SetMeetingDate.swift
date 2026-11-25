import Foundation
import CassiniCore

/// Prefill choice for the "When was this recorded?" sheet (D112 / L-87).
public struct SetMeetingDatePrefill: Equatable, Sendable {
    public var date: Date
    /// True only when the meeting had no recording time and the picker was prefilled from the
    /// imported file's last-saved time minus its length.
    public var showsSavedFileHint: Bool

    public init(date: Date, showsSavedFileHint: Bool) {
        self.date = date
        self.showsSavedFileHint = showsSavedFileHint
    }

    public static func of(note: Note, now: Date, calendar: Calendar) -> SetMeetingDatePrefill {
        switch note.meetingTime {
        case .instant(let instant):
            return SetMeetingDatePrefill(date: instant, showsSavedFileHint: false)
        case .local(let text):
            if let localDate = parseLocal(text, in: calendar) {
                return SetMeetingDatePrefill(date: localDate, showsSavedFileHint: false)
            }
        case .unknown:
            break
        }
        if let modified = note.sourceModifiedAt {
            let length = note.duration.isFinite && note.duration > 0 ? note.duration : 0
            return SetMeetingDatePrefill(date: modified.addingTimeInterval(-length), showsSavedFileHint: true)
        }
        return SetMeetingDatePrefill(date: now, showsSavedFileHint: false)
    }

    private static func parseLocal(_ text: String, in calendar: Calendar) -> Date? {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#,
                         options: .regularExpression) != nil else { return nil }
        let numbers = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard numbers.count == 6 else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        return calendar.date(from: components)
    }
}

/// Pure formatting and application rules for Set date and time (D112 / L-87).
public enum SetMeetingDate {
    /// Floors `date` to whole seconds so the stored `Date` instant matches the RFC 3339 string.
    public static func flooredToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    /// Formats `date` in `timeZone` as RFC 3339 with explicit UTC offset (`YYYY-MM-DDTHH:MM:SS±HH:MM`),
    /// seconds floored, matching `meeting.schema.json`'s `startedAt` pattern (never `-00:00`).
    public static func formatStartedAt(_ date: Date, timeZone: TimeZone) -> String {
        let floored = flooredToSecond(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: floored)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = parts.second ?? 0
        let offsetSeconds = timeZone.secondsFromGMT(for: floored)
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absMinutes = abs(offsetSeconds) / 60
        let offH = absMinutes / 60
        let offM = absMinutes % 60
        let offset = String(format: "%@%02d:%02d", sign, offH, offM)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@", year, month, day, hour, minute, second, offset)
    }

    /// Applies the user-selected date and time to `note`, preserving `createdAt` and filenames.
    public static func apply(date: Date, timeZone: TimeZone, to note: inout Note) {
        let floored = flooredToSecond(date)
        let formatted = formatStartedAt(floored, timeZone: timeZone)
        note.meetingTime = .instant(floored)
        note.userStartedAt = CassiniDocument.isValidStartedAt(formatted) ? formatted : nil
    }
}
