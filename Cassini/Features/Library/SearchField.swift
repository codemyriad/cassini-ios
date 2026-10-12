import SwiftUI

struct SearchField: View {
    @Binding var query: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.muted)
            TextField("Search recordings and words", text: $query).font(.body).autocorrectionDisabled().accessibilityIdentifier("librarySearch")
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).foregroundStyle(Color.muted)
            }
        }
        .padding(15).cardBackground(radius: Radius.control, outlined: false)
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color.ink.opacity(0.07), lineWidth: 1))
    }
}
