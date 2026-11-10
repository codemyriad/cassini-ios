import SwiftUI

extension Binding where Value == String {
    /// Below iOS 26, this binding also hands each edit of a text field to `edited` as the field writes it. A field
    /// whose edits change something else (a model, a draft, a cut to a limit) passes it to the field and keeps its
    /// `onChange(of:)`; iOS 26 keeps `onChange(of:)` alone.
    ///
    /// On iOS 18.2 under load, SwiftUI skips an `onChange(of:)` action when the value changes twice within one frame
    /// (it logs "onChange(of: String) action tried to update multiple times per frame"), so a fast typist's last
    /// keystroke can reach the field's text but not its `onChange` action, which then waits for the next edit. In Name a
    /// speaker the text held "Anna Ricci" while the model kept "Anna Ric", and Save stored "Anna Ric". The text
    /// field writes its binding on every edit, so the action runs from here too. `onChange(of:)` still runs for changes
    /// made in code, so `edited` may see an edit twice and must give the same result when it does.
    func handingEdits(to edited: @escaping @MainActor (String) -> Void) -> Binding<String> {
        if #available(iOS 26.0, *) { return self }
        return Binding(get: { wrappedValue }, set: { text, transaction in
            self.transaction(transaction).wrappedValue = text
            MainActor.assumeIsolated { edited(text) }
        })
    }
}
