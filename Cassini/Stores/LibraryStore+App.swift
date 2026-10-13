import Foundation
import CassiniEngine

extension LibraryStore {
    /// The library under `root`, its failed writes shown by `errors`.
    convenience init(root: URL, errors: ErrorPresenter) {
        self.init(root: root, reportFailure: Self.saveFailure(errors))
    }

    /// A library over `noteStore`, for tests.
    convenience init(noteStore: NoteStore, errors: ErrorPresenter) {
        self.init(noteStore: noteStore, reportFailure: Self.saveFailure(errors))
    }

    private static func saveFailure(_ errors: ErrorPresenter) -> @MainActor (any Error) -> Void {
        { error in
            errors.present(String(localized: "Could not save changes: \(FailureReason.of(error))", table: "Failures"))
        }
    }
}
