import SwiftUI

struct InNoteSearchBar: View {
    @Binding var query: String
    let close: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField("Find in transcript", text: $query).autocorrectionDisabled().accessibilityIdentifier("transcriptSearch")
            Button("Close search", systemImage: "xmark.circle.fill", action: close).labelStyle(.iconOnly)
        }.padding(14).cardBackground(radius: Radius.field, outlined: false)
    }
}
