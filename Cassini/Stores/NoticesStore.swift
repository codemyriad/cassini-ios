import Foundation
import Observation

/// Messages shown at the top of the Library until dismissed. Each new one is added; none replaces another.
@MainActor @Observable final class NoticesStore {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    private(set) var notices: [Notice] = []

    func post(_ text: String) {
        guard !notices.contains(where: { $0.text == text }) else { return }
        notices.append(Notice(text: text))
    }

    func dismiss(_ id: Notice.ID) { notices.removeAll { $0.id == id } }
}
