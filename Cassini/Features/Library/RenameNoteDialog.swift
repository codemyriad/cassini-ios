import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Rename, from the Library and from the note screen alike (Android uses one Rename dialog for both): `RenameSheet`
/// with the 200-character limit and "Enter a title."; Save stores the trimmed title (`LibraryScreenModel.rename`).
struct RenameNoteDialog: View {
    let noteID: UUID
    var draft: String?
    var titleChanged: (String) -> Void = { _ in }
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryScreenModel.self) private var model

    var body: some View {
        RenameSheet(navigationTitle: LibraryCopy.rename, fieldLabel: LibraryCopy.titleLabel,
                    original: library.note(noteID)?.title ?? "", draft: draft, limit: NoteTitles.maxLength,
                    blankMessage: LibraryCopy.titleBlank, saveLabel: LibraryCopy.save, cancelLabel: LibraryCopy.cancel,
                    clean: NoteTitles.clean, textChanged: titleChanged) { model.rename(noteID, to: $0) }
    }
}
