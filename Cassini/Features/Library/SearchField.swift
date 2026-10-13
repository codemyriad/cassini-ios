import SwiftUI

/// The Library search: Search on the keyboard hides it, and a 44 pt Clear search button shows while there is text.
/// The privacy line sits under it.
struct SearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.muted).accessibilityHidden(true)
                // At accessibility sizes the long placeholder would be cut; "Search" says enough.
                TextField(dynamicType.isAccessibilitySize ? LibraryCopy.searchPlaceholderShort : LibraryCopy.searchPlaceholder,
                          text: $query, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.body).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.search).focused($focused).onSubmit { focused = false }
                    // A field that wraps takes Search as a new line rather than a submit: it ends the search instead.
                    .onChange(of: query) { _, text in
                        guard text.contains(where: \.isNewline) else { return }
                        query = text.filter { !$0.isNewline }
                        focused = false
                    }
                    .accessibilityIdentifier("librarySearch")
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
}
