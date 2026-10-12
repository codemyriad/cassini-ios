import Foundation
import Observation
import CassiniNotebook

/// The confirmations of the Recently Deleted screen (Android's `TrashViewModel` dialogs): Delete now and Empty ask
/// first, Cancel keeps everything, and Delete runs the delete once the dialog has closed. `request` is small and
/// `Codable`, so the screen keeps it with the scene and the open dialog comes back after Cassini was closed.
@MainActor @Observable public final class TrashDialogs {
    public var request: TrashDialogRequest?

    public init(request: TrashDialogRequest? = nil) { self.request = request }

    /// The dialog to show over `items`, if any.
    public func dialog(in items: [TrashItem]) -> TrashDialog? { request?.dialog(in: items) }

    /// "Delete now" on a card.
    public func askDeleteNow(_ id: UUID) { request = .delete(id) }

    /// "Empty": asks with the count; asks nothing while Recently Deleted is empty.
    public func askEmpty(items: [TrashItem]) {
        if !items.isEmpty { request = .empty }
    }

    /// Cancel: the dialog closes and nothing is deleted.
    public func dismiss() { request = nil }

    /// Delete in `dialog`: it closes, then its notes are deleted for good.
    public func confirm(_ dialog: TrashDialog, with trash: TrashService) async throws(TrashError) {
        request = nil
        switch dialog {
        case .delete(let id, _): try await trash.deleteNow(id)
        case .emptyAll: try await trash.emptyTrash()
        }
    }
}
