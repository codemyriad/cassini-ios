import Foundation
import CassiniNotebook

/// The words of Recently Deleted, its confirmations and the Undo snackbar (the Trash table).
enum TrashCopy {
    static let title = String(localized: "Recently Deleted", table: "Trash", comment: "The Recently Deleted screen's title")
    static let empty = String(localized: "Empty", table: "Trash", comment: "Recently Deleted toolbar: delete every note there")
    static let intro = String(localized: "Notes here are deleted for good after 30 days, with their audio, transcripts and voiceprints from those notes.",
                              table: "Trash", comment: "Recently Deleted intro")
    static let restore = String(localized: "Restore", table: "Trash", comment: "Recently Deleted card: put the note back in the library")
    static let deleteNow = String(localized: "Delete now", table: "Trash", comment: "Recently Deleted card: delete the note for good")
    static let delete = String(localized: "Delete", table: "Trash", comment: "Confirmation button: delete for good")
    static let cancel = String(localized: "Cancel", table: "Trash", comment: "Confirmation button: keep everything")
    static let isEmpty = String(localized: "Recently Deleted is empty", table: "Trash", comment: "Recently Deleted with no notes")
    static let isEmptyBody = String(localized: "Notes you delete stay here for 30 days.", table: "Trash",
                                    comment: "Recently Deleted with no notes, body")
    static let deleteBody = String(localized: "Its audio, transcripts and voiceprints from this note are deleted. This can’t be undone.",
                                   table: "Trash", comment: "Delete now confirmation body")
    static let deleteAllBody = String(localized: "Their audio, transcripts and voiceprints are deleted. This can’t be undone.",
                                      table: "Trash", comment: "Empty confirmation body")
    static let undo = String(localized: "Undo", table: "Trash", comment: "Library snackbar action: put the note back")
    static let moveToTrash = String(localized: "Move to Recently Deleted", table: "Trash", comment: "Note action and confirmation button")
    static let stopAndTrash = String(localized: "Stop transcription and move to Recently Deleted?", table: "Trash",
                                     comment: "Confirmation before moving a note whose transcription runs")
    static let keptFor30Days = String(localized: "Kept for 30 days, then deleted.", table: "Trash",
                                      comment: "Confirmation body before moving a note to Recently Deleted")
    static let voicesUnavailable = String(localized: "Saved voices could not be read, so nothing was deleted. Their files are kept.",
                                          table: "Trash", comment: "Delete now or Empty while the saved voices cannot be read")

    static func deleteTitle(_ title: String) -> String {
        String(localized: "Delete “\(title)” for good?", table: "Trash", comment: "Delete now confirmation title")
    }

    static func deleteAllTitle(_ count: Int) -> String {
        String(localized: "Delete \(count) notes for good?", table: "Trash", comment: "Empty confirmation title")
    }

    static func moved(_ title: String) -> String {
        String(localized: "“\(title)” moved to Recently Deleted", table: "Trash",
               comment: "Library snackbar after a note was moved to Recently Deleted")
    }

    /// Delete now or Empty left `ids`: the note by its title when one stayed, else how many.
    static func notDeleted(_ ids: [UUID], in items: [TrashItem]) -> String {
        if ids.count == 1, let title = items.first(where: { $0.id == ids[0] })?.title {
            return String(localized: "“\(title)” could not be deleted. It stays in Recently Deleted.", table: "Trash",
                          comment: "Delete now or Empty failed for one note")
        }
        return String(localized: "\(ids.count) notes could not be deleted. They stay in Recently Deleted.", table: "Trash",
                      comment: "Empty failed for several notes; the others were deleted")
    }

    static func daysLeft(_ days: Int) -> String {
        String(localized: "\(days) days left", table: "Trash", comment: "Recently Deleted card: days before the note is deleted for good")
    }

    /// "Deleted today", "Deleted yesterday" or "Deleted 2 Oct" (Android's `Dates.deleted`; with the year outside the
    /// current one).
    static func deleted(_ day: TrashDay, calendar: Calendar) -> String {
        switch day {
        case .today:
            return String(localized: "Deleted today", table: "Trash", comment: "Recently Deleted card: the note was deleted today")
        case .yesterday:
            return String(localized: "Deleted yesterday", table: "Trash", comment: "Recently Deleted card: the note was deleted yesterday")
        case .date(let date, let withYear):
            let text = DateLabels(calendar: calendar).shortDate(date, withYear: withYear)
            return String(localized: "Deleted \(text)", table: "Trash",
                          comment: "Recently Deleted card: the day the note was deleted, e.g. Deleted 2 Oct")
        }
    }
}
