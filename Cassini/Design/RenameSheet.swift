import SwiftUI
import CassiniNotebook

/// The Rename form shared by a note's title and a saved voice's name (Android's rename dialogs): the field stops at
/// `limit` characters, a blank one says `blankMessage` under the field, and Save, which hands `save` the cleaned text,
/// is on only when it changed. A sheet rather than an alert, because an iOS alert's text field takes no inline error.
/// The screen that opens it keeps the text being typed (`textChanged`) and hands it back as `draft` when the sheet
/// opens again after Cassini was closed.
struct RenameSheet: View {
    let navigationTitle: String
    let fieldLabel: String
    let original: String
    var draft: String?
    let limit: Int
    let blankMessage: String
    let saveLabel: String
    let cancelLabel: String
    var fieldIdentifier = "renameField"
    var capitalization: TextInputAutocapitalization = .sentences
    /// The text as it is stored, or nil when it may not be (blank).
    let clean: (String) -> String?
    var textChanged: (String) -> Void = { _ in }
    /// Stores the cleaned text; false keeps the sheet open.
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var cleaned: String? { clean(String(text.prefix(limit))) }
    private var canSave: Bool { cleaned.map { $0 != original } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fieldLabel, text: $text.handingEdits(to: edited))
                        .focused($focused).submitLabel(.done).onSubmit(confirm)
                        .textInputAutocapitalization(capitalization)
                        .onChange(of: text) { _, typed in edited(typed) }
                        .accessibilityIdentifier(fieldIdentifier)
                } footer: {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(blankMessage).foregroundStyle(Tone.error.color)
                    }
                }
            }
            .paperListBackground()
            .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(cancelLabel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saveLabel, action: confirm).disabled(!canSave) }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear {
            text = draft ?? original
            focused = true
        }
    }

    /// Cuts text past the limit, or hands it to the screen that keeps it. Below iOS 26 this runs from the field's
    /// binding too (`handingEdits`), since SwiftUI can skip the `onChange` of a fast typist's last keystroke there; a
    /// second run for the same text changes nothing.
    private func edited(_ typed: String) {
        if typed.count > limit {
            // Finish the native paste transaction before writing its shortened value back.
            // A synchronous write here can leave the field showing the uncut paste on iOS 26.
            DispatchQueue.main.async {
                guard text == typed else { return }
                text = String(typed.prefix(limit))
            }
        } else { textChanged(typed) }
    }

    private func confirm() {
        guard canSave, let cleaned, save(cleaned) else { return }
        dismiss()
    }
}
