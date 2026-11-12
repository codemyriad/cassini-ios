import Foundation

/// D50.3: date words/pattern and duration words follow the UI; clock cycle/digits follow formatting preferences.
public enum MarkdownDate {
    public static func uiLocale(_ language: String) -> Locale {
        let tag = language.replacingOccurrences(of: "_", with: "-")
        let base = tag.split(separator: "-").first.map(String.init) ?? "en"
        if base == "pt" { return Locale(identifier: tag == "pt" || tag == "pt-BR" ? "pt_BR" : "pt_PT") }
        return Locale(identifier: ["it", "fr", "es"].contains(base) ? base : "en_GB")
    }

    /// D95: unknown timestamps never borrow a seal/import date; local labels stay as written.
    /// This is the same fallback as Android's NoteMarkdown: label and duration, or duration alone.
    public static func line(meetingTime: MeetingTime, timeZone: TimeZone, uiLanguage: String,
                            formattingLocale: Locale, is24Hour: Bool? = nil, duration: String? = nil) -> String {
        if case .instant(let date) = meetingTime {
            return line(at: date, timeZone: timeZone, uiLanguage: uiLanguage, formattingLocale: formattingLocale,
                        is24Hour: is24Hour, duration: duration)
        }
        return [meetingTime.localText, duration].compactMap { $0 }.joined(separator: " · ")
    }

    public static func line(at date: Date, timeZone: TimeZone, uiLanguage: String, formattingLocale: Locale,
                            is24Hour: Bool? = nil, duration: String? = nil) -> String {
        let words = DateFormatter()
        words.locale = uiLocale(uiLanguage)
        words.calendar = Calendar(identifier: .gregorian)
        words.timeZone = timeZone
        if words.locale.language.languageCode?.identifier == "en" { words.dateFormat = "EEEE d MMMM y" }
        else { words.dateStyle = .full; words.timeStyle = .none }
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: formattingLocale) ?? ""
        let twentyFour = is24Hour ?? (pattern.contains("H") || pattern.contains("k"))
        let clock = DateFormatter()
        clock.locale = formattingLocale
        clock.calendar = Calendar(identifier: .gregorian)
        clock.timeZone = timeZone
        clock.dateFormat = twentyFour ? "HH:mm" : "h:mm a"
        return words.string(from: date) + ", " + clock.string(from: date) + (duration.map { " · " + $0 } ?? "")
    }

    public static func duration(_ ms: Int64, locale: Locale, underMinute: String, minutes: String, hours: String) -> String? {
        guard ms > 0 else { return nil }
        guard ms >= 60_000 else { return underMinute }
        let number = NumberFormatter()
        number.locale = locale; number.numberStyle = .decimal; number.usesGroupingSeparator = false
        number.maximumFractionDigits = 0
        func digits(_ value: Int64) -> String { number.string(from: NSNumber(value: value)) ?? String(value) }
        let total = ms / 60_000
        guard total >= 60 else { return minutes.replacingOccurrences(of: "{m}", with: digits(total)) }
        let h = digits(total / 60)
        number.minimumIntegerDigits = 2
        return hours.replacingOccurrences(of: "{h}", with: h).replacingOccurrences(of: "{mm}", with: digits(total % 60))
    }
}
