import Foundation

extension Note {
    /// Marks a moment, unless one is already within a second of it; bookmarks stay in time order. The caller makes
    /// the id, so a note edit that adds a bookmark gives the same bookmark each time it runs.
    public mutating func addBookmark(at time: Double, id: UUID) {
        guard !bookmarks.contains(where: { abs($0.time - time) < 1 }) else { return }
        bookmarks.append(Bookmark(id: id, time: min(time, max(duration, time)), label: "Moment at \(TimeText.clock(time))"))
        bookmarks.sort { $0.time < $1.time }
    }
}
