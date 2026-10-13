import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Rename, from the Library and from the note screen alike (Android uses one Rename dialog for both): the field stops
/// at the 200-character limit, a blank title says "Enter a title.", and Save, which stores the trimmed title
/// (`LibraryScreenModel.rename`), is on only when the title changed. A sheet rather than Android's alert, so the
/// blank-title error can sit under the field. The screen that opens it keeps the title being typed (`titleChanged`) and
/// hands it back as `draft` when the sheet opens again after Cassini was closed.
struct RenameNoteDialog: View {
    let noteID: UUID
    var draft: String?
    var titleChanged: (String) -> Void = { _ in }
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryScreenModel.self) private var model
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
                            else { titleChanged(text) }
                        }
                        .accessibilityIdentifier("renameField")
                } footer: {
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(LibraryCopy.titleBlank).foregroundStyle(Tone.error.color)
                    }
                }
            }
            .paperListBackground()
            .navigationTitle(LibraryCopy.rename).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LibraryCopy.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LibraryCopy.save, action: save).disabled(!canSave) }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear {
            original = library.note(noteID)?.title ?? ""
            title = draft ?? original
            focused = true
        }
    }

    private func save() {
        guard canSave, model.rename(noteID, to: title) else { return }
        dismiss()
    }
}
