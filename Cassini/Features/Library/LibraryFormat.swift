import Foundation
import CassiniNotebook

/// Day headers, times and the VoiceOver forms of the Library, in the app's calendar (its zone and locale).
struct LibraryFormat {
    let calendar: Calendar
    var locale: Locale { calendar.locale ?? .current }

    private var dates: DateLabels { DateLabels(calendar: calendar) }

    /// "Today", "Yesterday", "Monday 5 Oct", "5 Oct 2025" (`DateLabels.day`).
    func day(_ key: DayKey) -> String { dates.day(key) }

    /// "9:41 AM", "09:41".
    func time(_ date: Date) -> String { dates.time(date) }

    /// "Today, 9:41 AM": the meta line of a search result.
    func dayTime(_ key: DayKey, _ date: Date) -> String { LibraryCopy.dayTime(day(key), time(date)) }

    /// "today 9:41 AM", for VoiceOver.
    func spokenDayTime(_ key: DayKey, _ date: Date) -> String {
        let day = switch key {
        case .undated: ""
        case .today: LibraryCopy.todayInline
        case .yesterday: LibraryCopy.yesterdayInline
        case .date: self.day(key)
        }
        return LibraryCopy.spokenDayTime(day, time(date))
    }

    /// The meeting's own date only; never a seal/import/sorting fallback.
    func meetingTime(_ row: LibraryRow, spoken: Bool = false, day: DayKey? = nil) -> String? {
        switch row.meetingTime {
        case .instant(let date):
            if let key = day ?? row.day {
                return spoken ? spokenDayTime(key, date) : dayTime(key, date)
            }
            return time(date)
        case .local(let text): return text
        case .unknown: return nil
        }
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
        var parts = [row.title, spokenDuration(row.duration)]
        if let date = meetingTime(row, spoken: true, day: row.day ?? day) { parts.append(date) }
        let status = row.isSavingCapture
            ? StatusBadgeCopy.template("states.badge.saving", language: locale.identifier)
            : LibraryCopy.status(row.status)
        parts.append(status.lowercased(with: locale))
        if row.status.suffix != .resume, row.status.suffix != .tryAgain, let suffix = LibraryCopy.suffix(row.status) {
            parts.append(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "·").union(.whitespaces)).lowercased(with: locale))
        }
        if row.isFavorite { parts.append(LibraryCopy.starredLabel.lowercased(with: locale)) }
        if let preview = row.preview { parts.append(preview.text) }
        return parts.joined(separator: ", ")
    }
}
