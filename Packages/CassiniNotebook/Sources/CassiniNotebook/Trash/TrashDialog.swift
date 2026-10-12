import Foundation

/// A confirmation Recently Deleted asked for. Small and `Codable`, so the screen keeps it with the scene and the open
/// dialog comes back after Cassini was closed.
public enum TrashDialogRequest: Codable, Hashable, Sendable {
    /// "Delete now" on one note.
    case delete(UUID)
    /// "Empty".
    case empty

    /// The dialog to show over `items`: none once its note left Recently Deleted, or for Empty once it is empty.
    public func dialog(in items: [TrashItem]) -> TrashDialog? {
        switch self {
        case .empty:
            items.isEmpty ? nil : .emptyAll(count: items.count)
        case .delete(let id):
            items.first { $0.id == id }.map { .delete(id: $0.id, title: $0.title) }
        }
    }
}

/// "Delete “title” for good?", or "Delete N notes for good?".
public enum TrashDialog: Hashable, Sendable {
    case delete(id: UUID, title: String)
    case emptyAll(count: Int)
}
