import Foundation

/// How long a note stays in Recently Deleted. Days are calendar days in the device's time zone, so a daylight-saving
/// change never moves the purge: a note deleted on 2 October has 23 days left on 9 October and expires on 1 November.
public enum TrashPolicy {
    public static let retentionDays = 30

    /// How long the "moved to Recently Deleted" snackbar stays: 10 s, and 30 s while VoiceOver runs, so there is time to
    /// hear it and reach Undo (Android asks the accessibility settings for their recommended timeout).
    public static func undoDuration(voiceOverRunning: Bool) -> Duration {
        voiceOverRunning ? .seconds(30) : .seconds(10)
    }

    /// Days left before the note deleted at `deleted` is deleted for good, seen at `now`: 30 on the day it was deleted,
    /// 0 from the 30th day after. Clamped to 0...30, so a clock set back adds no days.
    public static func daysLeft(since deleted: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: deleted),
                                              to: calendar.startOfDay(for: now)).day ?? 0
        return min(retentionDays, max(0, retentionDays - elapsed))
    }

    public static func isExpired(since deleted: Date, now: Date, calendar: Calendar) -> Bool {
        daysLeft(since: deleted, now: now, calendar: calendar) == 0
    }

    /// The moment before which a deleted note is expired at `now`: the start of the local day 29 days before today.
    /// `deleted < purgeCutoff` is the same test as `isExpired`.
    public static func purgeCutoff(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) ?? today
        return calendar.startOfDay(for: day)
    }
}
