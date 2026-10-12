import Foundation
import Testing
@testable import CassiniNotebook

/// The confirmations of Recently Deleted: which one shows over the cards, and that it survives being stored.
struct TrashDialogTests {
    private let a = TrashItem(id: UUID(), title: "Test recording", duration: 60, deletedOn: .today, daysLeft: 30)
    private let b = TrashItem(id: UUID(), title: "Standup", duration: 0, deletedOn: .yesterday, daysLeft: 29)

    @Test func deleteNowAsksAboutItsNoteAndTheRequestSurvivesBeingStored() throws {
        let request = TrashDialogRequest.delete(a.id)
        #expect(request.dialog(in: [a, b]) == .delete(id: a.id, title: "Test recording"))
        let restored = try JSONDecoder().decode(TrashDialogRequest.self, from: JSONEncoder().encode(request))
        #expect(restored.dialog(in: [a, b]) == .delete(id: a.id, title: "Test recording"))
    }

    @Test func aDialogGoesWhenItsNoteLeftRecentlyDeleted() {
        #expect(TrashDialogRequest.delete(a.id).dialog(in: [b]) == nil)
    }

    @Test func emptyAsksWithTheCountAndAsksNothingOnceEmpty() {
        #expect(TrashDialogRequest.empty.dialog(in: [a, b]) == .emptyAll(count: 2))
        #expect(TrashDialogRequest.empty.dialog(in: []) == nil)
    }
}
