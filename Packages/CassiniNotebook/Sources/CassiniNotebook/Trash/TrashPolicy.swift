import Foundation

public enum TrashPolicy {
    public static let retentionDays = 30
    public static func daysLeft(since deleted: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: deleted), to: calendar.startOfDay(for: now)).day ?? 0
        return min(retentionDays, max(0, retentionDays - elapsed))
    }
}
