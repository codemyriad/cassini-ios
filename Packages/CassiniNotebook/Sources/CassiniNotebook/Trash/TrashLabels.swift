import Foundation

/// The day a note was deleted, as its Recently Deleted card says it: "Deleted today", "Deleted yesterday", or the
/// date, with the year only when it is not the current one.
public enum TrashDay: Hashable, Sendable {
    case today
    case yesterday
    /// The start of the local day.
    case date(Date, withYear: Bool)

    /// The day of `date` seen at `now`, in calendar days of `calendar`'s time zone.
    public init(_ date: Date, now: Date, calendar: Calendar) {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today {
            self = .today
        } else if calendar.date(byAdding: .day, value: -1, to: today) == day {
            self = .yesterday
        } else {
            self = .date(day, withYear: calendar.component(.year, from: day) != calendar.component(.year, from: today))
        }
    }
}

/// One card of Recently Deleted.
public struct TrashItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var duration: TimeInterval
    public var deletedOn: TrashDay
    public var daysLeft: Int

    public init(id: UUID, title: String, duration: TimeInterval, deletedOn: TrashDay, daysLeft: Int) {
        self.id = id; self.title = title; self.duration = duration; self.deletedOn = deletedOn; self.daysLeft = daysLeft
    }
}

/// A note that was just moved to Recently Deleted: the Library offers Undo for it.
public struct TrashedNote: Hashable, Sendable {
    public var noteID: UUID
    public var title: String
    public init(noteID: UUID, title: String) { self.noteID = noteID; self.title = title }
}

public enum TrashLabels {
    /// The notes in Recently Deleted as cards, oldest deletion first (the soonest to expire on top), ties by id.
    public static func items(_ notes: [Note], now: Date, calendar: Calendar) -> [TrashItem] {
        notes.compactMap { note in note.trashedAt.map { (note, $0) } }
            .sorted { ($0.1, $0.0.id.uuidString) < ($1.1, $1.0.id.uuidString) }
            .map { note, deleted in
                TrashItem(id: note.id, title: note.title, duration: note.duration,
                          deletedOn: TrashDay(deleted, now: now, calendar: calendar),
                          daysLeft: TrashPolicy.daysLeft(since: deleted, now: now, calendar: calendar))
            }
    }
}
