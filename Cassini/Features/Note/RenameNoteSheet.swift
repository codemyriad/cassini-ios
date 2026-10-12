import SwiftUI
import CassiniNotebook

struct RenameNoteSheet: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form { TextField(NoteCopy.titleField, text: $title).accessibilityIdentifier("recordingTitleField") }
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
        .onAppear { title = library.note(noteID)?.title ?? "" }
    }
}
