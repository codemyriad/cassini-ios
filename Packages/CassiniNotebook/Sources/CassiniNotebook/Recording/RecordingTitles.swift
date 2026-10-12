import Foundation

/// The dates in the titles Cassini gives recordings: "Voice note 8 Oct, 08:14" for a new one, "Recovered recording
/// 8 Oct" for one rebuilt from its audio. The words around them come from the app's string tables.
public enum RecordingTitles {
    /// "8 Oct, 08:14": the day, the short month in `locale`'s words and the 24-hour time, as on Android, in every
    /// language. Abbreviation dots are dropped ("8 ott, 08:14").
    public static func dateTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        format(date, "d MMM, HH:mm", locale: locale, timeZone: timeZone)
    }

    /// "8 Oct".
    public static func day(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        format(date, "d MMM", locale: locale, timeZone: timeZone)
    }

    private static func format(_ date: Date, _ pattern: String, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = pattern
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}
