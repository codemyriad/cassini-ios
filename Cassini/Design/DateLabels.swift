import Foundation
import CassiniNotebook

/// The app's dates in Android's forms (`Dates.dayLabel`, `shortDate`, `shortDateTime`), in the app's calendar (its
/// zone and locale), so a note's date reads the same in the Library, on its screen, in Versions and in Recently
/// Deleted: "Today", "Yesterday", "Monday 5 Oct", "5 Oct 2025"; "8 Oct"; "8 Oct, 9:41 AM". The year shows only for
/// another year.
struct DateLabels {
    let calendar: Calendar
    var locale: Locale { calendar.locale ?? .current }

    /// "Today", "Yesterday", "Monday 5 Oct", "5 Oct 2025".
    func day(_ key: DayKey) -> String {
        switch key {
        case .undated: return Self.unknownDate()
        case .today: return LibraryCopy.today
        case .yesterday: return LibraryCopy.yesterday
        case .date(let day, let withYear):
            guard let date = day.start(in: calendar) else { return "" }
            return formatted(date, withYear ? "d MMM yyyy" : "EEEE d MMM").capitalized(firstLetterIn: locale)
        }
    }

    /// Shared `library.group.unknownDate`; a section remains named for sighted and VoiceOver users.
    static func unknownDate(bundle: Bundle = .main) -> String {
        String(localized: "Date unknown", table: "Library", bundle: bundle,
               comment: "Shared catalog library.group.unknownDate: Library section for an unknown meeting date")
    }

    /// "9:41 AM", "09:41".
    func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar; style.timeZone = calendar.timeZone; style.locale = locale
        return date.formatted(style)
    }

    /// "8 Oct", "8 Oct 2025".
    func shortDate(_ date: Date, withYear: Bool) -> String { formatted(date, withYear ? "d MMM yyyy" : "d MMM") }

    /// "8 Oct, 9:41 AM", with the year when `date` is not in the year of `now`.
    func shortDateTime(_ date: Date, now: Date) -> String {
        let withYear = calendar.component(.year, from: date) != calendar.component(.year, from: now)
        return LibraryCopy.dayTime(shortDate(date, withYear: withYear), time(date))
    }

    private func formatted(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private extension String {
    /// "lunedì 5 ott" → "Lunedì 5 ott": a header starts with a capital in every language.
    func capitalized(firstLetterIn locale: Locale) -> String {
        guard let first else { return self }
        return String(first).uppercased(with: locale) + dropFirst()
    }
}
