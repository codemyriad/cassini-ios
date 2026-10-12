import SwiftUI
import CassiniNotebook

struct RenameNoteSheet: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Recording title", text: $title).accessibilityIdentifier("recordingTitleField") }
                .navigationTitle("Rename recording").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
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
