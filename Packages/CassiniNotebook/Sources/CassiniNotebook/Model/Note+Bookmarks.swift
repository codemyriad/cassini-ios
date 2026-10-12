import Foundation

extension Note {
    /// Marks a moment, unless one is already within a second of it; bookmarks stay in time order.
    public mutating func addBookmark(at time: Double) {
        guard !bookmarks.contains(where: { abs($0.time - time) < 1 }) else { return }
        bookmarks.append(Bookmark(time: min(time, max(duration, time)), label: "Moment at \(TimeText.clock(time))"))
        bookmarks.sort { $0.time < $1.time }
    }
}
