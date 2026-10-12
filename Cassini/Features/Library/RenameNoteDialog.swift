import SwiftUI
import CassiniNotebook

/// Rename from the Library (Android's Rename dialog): the field stops at the 200-character limit, a blank title says
/// "Enter a title.", and Save, which stores the trimmed title, is on only when the title changed.
struct RenameNoteDialog: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var original = ""
    @FocusState private var focused: Bool

    private var cleaned: String? { NoteTitles.clean(title) }
    private var canSave: Bool { cleaned.map { $0 != original } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LibraryCopy.titleLabel, text: $title)
                        .focused($focused).submitLabel(.done).onSubmit(save)
                        .onChange(of: title) { _, text in
                            if text.count > NoteTitles.maxLength { title = String(text.prefix(NoteTitles.maxLength)) }
                        }
                        .accessibilityIdentifier("renameField")
                } footer: {
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(LibraryCopy.titleBlank).foregroundStyle(Tone.error.color)
                    }
                }
            }
            .navigationTitle(LibraryCopy.rename).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LibraryCopy.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LibraryCopy.save, action: save).disabled(!canSave) }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear {
            original = library.note(noteID)?.title ?? ""
            title = original
            focused = true
        }
    }

    private func save() {
        guard canSave, let cleaned else { return }
        library.update(noteID) { $0.title = cleaned }
        dismiss()
    }
}
