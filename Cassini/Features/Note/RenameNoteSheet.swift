import SwiftUI
import CassiniNotebook

/// Rename on the Note screen. The screen keeps the title being typed (`titleChanged`) and hands it back as `draft`
/// when the sheet opens again after Cassini was closed.
struct RenameNoteSheet: View {
    let noteID: UUID
    var draft: String?
    var titleChanged: (String) -> Void = { _ in }
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form { TextField(NoteCopy.titleField, text: $title).accessibilityIdentifier("recordingTitleField")
                    .onChange(of: title) { _, title in titleChanged(title) } }
                .navigationTitle(NoteCopy.rename).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(NoteCopy.cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NoteCopy.save) {
                            guard let fitted = NoteTitles.fit(title) else { return }
                            if library.update(noteID, { $0.title = fitted }) { dismiss() }
                        }.disabled(NoteTitles.fit(title) == nil)
                    }
                }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear { title = draft ?? library.note(noteID)?.title ?? "" }
    }
}
