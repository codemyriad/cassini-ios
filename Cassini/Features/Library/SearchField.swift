import SwiftUI

/// The Library search: Search on the keyboard hides it, and a 44 pt Clear search button shows while there is text.
/// The privacy line sits under it.
struct SearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.muted).accessibilityHidden(true)
                TextField(LibraryCopy.searchPlaceholder, text: $query)
                    .font(.body).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.search).focused($focused).onSubmit { focused = false }
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
