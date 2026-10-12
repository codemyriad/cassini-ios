import Foundation
import CassiniNotebook

/// Day headers, times and the VoiceOver forms of the Library, in the app's calendar (its zone and locale).
struct LibraryFormat {
    let calendar: Calendar
    var locale: Locale { calendar.locale ?? .current }

    /// "Today", "Yesterday", "Monday 5 Oct", "5 Oct 2025".
    func day(_ key: DayKey) -> String {
        switch key {
        case .today: return LibraryCopy.today
        case .yesterday: return LibraryCopy.yesterday
        case .date(let day, let withYear):
            guard let date = day.start(in: calendar) else { return "" }
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
            formatter.dateFormat = withYear ? "d MMM yyyy" : "EEEE d MMM"
            return formatter.string(from: date).capitalized(firstLetterIn: locale)
        }
    }

    /// "9:41 AM", "09:41".
    func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar; style.timeZone = calendar.timeZone; style.locale = locale
        return date.formatted(style)
    }

    /// "Today, 9:41 AM": the meta line of a search result.
    func dayTime(_ key: DayKey, _ date: Date) -> String { LibraryCopy.dayTime(day(key), time(date)) }

    /// "today 9:41 AM", for VoiceOver.
    func spokenDayTime(_ key: DayKey, _ date: Date) -> String {
        let day = switch key {
        case .today: LibraryCopy.todayInline
        case .yesterday: LibraryCopy.yesterdayInline
        case .date: self.day(key)
        }
        return LibraryCopy.spokenDayTime(day, time(date))
    }

    /// "48 minutes, 13 seconds".
    func spokenDuration(_ seconds: TimeInterval) -> String {
        let whole = Int64(max(0, seconds.isFinite ? seconds : 0))
        var style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        style.locale = locale
        return Duration.seconds(whole).formatted(style)
    }

    /// The row as one VoiceOver element: "title, spoken duration, day time, status[, suffix][, preview]". A suffix
    /// that is a button (Resume, Try again) is a named action instead.
    func rowLabel(_ row: LibraryRow, day: DayKey) -> String {
        var parts = [row.title, spokenDuration(row.duration), spokenDayTime(row.day ?? day, row.createdAt),
                     LibraryCopy.status(row.status).lowercased(with: locale)]
        if row.status.suffix != .resume, row.status.suffix != .tryAgain, let suffix = LibraryCopy.suffix(row.status) {
            parts.append(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "·").union(.whitespaces)).lowercased(with: locale))
        }
        if row.isFavorite { parts.append(LibraryCopy.starredLabel.lowercased(with: locale)) }
        if let preview = row.preview { parts.append(preview.text) }
        return parts.joined(separator: ", ")
    }
}

private extension String {
    /// "lunedì 5 ott" → "Lunedì 5 ott": a header starts with a capital in every language.
    func capitalized(firstLetterIn locale: Locale) -> String {
        guard let first else { return self }
        return String(first).uppercased(with: locale) + dropFirst()
    }
}
