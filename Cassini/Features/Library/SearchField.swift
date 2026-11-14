import SwiftUI
import UIKit
import CassiniEngine

/// The pinned Library search. Submit dismisses the keyboard while results and their Close control stay open.
struct SearchField: View {
    static let identifier = "librarySearch"
    @Binding var query: String
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType
    /// The width the field's text has, for the placeholder that fits it on one line.
    @State private var textWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                OrbitMark(size: 22).opacity(query.isEmpty ? 1 : 0)
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(Color.ink2)
                    .opacity(query.isEmpty ? 0 : 1)
            }
            .frame(width: 22, height: 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isPresented ? LibraryPhase1Copy.searchResultsAccessibilityLabel : MeetingPhase1Copy.allMeetings)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("libraryHeading")
            .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
            TextField(LibraryPhase1Copy.searchAccessibilityLabel, text: $query,
                      prompt: Text(placeholder).foregroundStyle(Color.ink3), axis: .vertical)
                .lineLimit(1...3)
                .font(.body).autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search).focused($focused).onSubmit { focused = false }
                .onChange(of: query) { _, text in
                    guard text.contains(where: \.isNewline) else { return }
                    query = text.filter { !$0.isNewline }
                    focused = false
                }
                .accessibilityLabel(LibraryPhase1Copy.searchAccessibilityLabel)
                .accessibilityIdentifier(Self.identifier)
                .modifier(TextViewEdits(query: $query, focused: $focused))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            if !query.isEmpty {
                Button(LibraryCopy.clearSearch, systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).foregroundStyle(Color.muted)
                    .frame(width: HitTarget.minimum, height: HitTarget.minimum).contentShape(Rectangle())
            }
        }
        .padding(.leading, 14).padding(.trailing, query.isEmpty ? 14 : 2)
        .padding(.vertical, 3).frame(minHeight: 48)
        .meetingGlass(cornerRadius: 24)
        .onChange(of: focused) { _, value in if value { isPresented = true } }
        .onChange(of: isPresented) { _, value in if !value { focused = false } }
    }

    /// Android's placeholder where it fits on one line (a phone); in the iPad's narrower sidebar, or at large text
    /// sizes, a shorter one, down to "Search". The field wraps typed text, and a wrapped placeholder would too.
    private var placeholder: String {
        let candidates = [LibraryPhase1Copy.searchPlaceholder, LibraryPhase1Copy.searchTitle]
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
