import SwiftUI
import UIKit
import CassiniEngine

/// The Library search: Search on the keyboard hides it, and a 44 pt Clear search button shows while there is text.
/// The privacy line sits under it.
struct SearchField: View {
    static let identifier = "librarySearch"
    @Binding var query: String
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType
    /// The width the field's text has, for the placeholder that fits it on one line.
    @State private var textWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.muted).accessibilityHidden(true)
                TextField(placeholder, text: $query, prompt: Text(placeholder).foregroundStyle(Color.ink3), axis: .vertical)
                    .lineLimit(1...3)
                    .font(.body).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.search).focused($focused).onSubmit { focused = false }
                    // A field that wraps takes Search as a new line rather than a submit: it ends the search instead.
                    .onChange(of: query) { _, text in
                        guard text.contains(where: \.isNewline) else { return }
                        query = text.filter { !$0.isNewline }
                        focused = false
                    }
                    .accessibilityIdentifier(Self.identifier)
                    .modifier(TextViewEdits(query: $query, focused: $focused))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                if !query.isEmpty {
                    Button(LibraryCopy.clearSearch, systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly).foregroundStyle(Color.muted)
                        .frame(width: HitTarget.minimum, height: HitTarget.minimum).contentShape(Rectangle())
                }
            }
            .padding(.leading, 15).padding(.trailing, 4).frame(minHeight: 52)
            .cardBackground(radius: Radius.control, outlined: false)
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color.ink.opacity(0.07), lineWidth: 1))
            Label(LibraryCopy.privacy, systemImage: "lock.shield")
                .font(.caption).foregroundStyle(Color.muted).padding(.leading, 4)
        }
    }

    /// Android's placeholder where it fits on one line (a phone); in the iPad's narrower sidebar, or at large text
    /// sizes, a shorter one, down to "Search". The field wraps typed text, and a wrapped placeholder would too.
    private var placeholder: String {
        let candidates = [LibraryCopy.searchPlaceholder, LibraryCopy.searchPlaceholderMedium, LibraryCopy.searchPlaceholderShort]
        guard textWidth > 0 else { return candidates[0] }
        let category = UIContentSizeCategory(dynamicType)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        return candidates.first { ($0 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) <= textWidth }
            ?? candidates[candidates.count - 1]
    }
}

/// Below iOS 26, every edit of the field is also read from its text view. Under load on iPadOS 18 the wrapping field
/// stopped passing edits to `query` mid-word (it held "Thur" while the field showed "Thursday" and Search's new line),
/// so neither the new line nor the end of editing above ever happened and the keyboard stayed up. The text view still
/// posts each change, Search's new line included; this takes the query from it and ends editing there. iOS 26 keeps the
/// binding alone.
private struct TextViewEdits: ViewModifier {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.onReceive(NotificationCenter.default.publisher(for: UITextView.textDidChangeNotification)) { note in
                guard let view = note.object as? UITextView, view.accessibilityIdentifier == SearchField.identifier,
                      let text = view.text else { return }
                switch LibrarySearchEdit(text: text, query: query, composing: view.markedTextRange != nil) {
                case .none: break
                case .follow(let typed): query = typed
                case .submit(let typed):
                    view.text = typed
                    query = typed
                    focused.wrappedValue = false
                    view.resignFirstResponder()
                }
            }
        }
    }
}
