import SwiftUI

/// In-note search: the field, "3 of 12" or "No matches", previous and next (they wrap around), and Close search.
struct InNoteSearchBar: View {
    @Binding var query: String
    let current: Int
    let total: Int
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.muted).accessibilityHidden(true)
            TextField(NoteCopy.searchInTranscript, text: $query, prompt: Text(NoteCopy.searchInTranscript).foregroundStyle(Color.ink3))
                .autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search)
                .focused($focused)
                .onSubmit(next)
                .accessibilityIdentifier("transcriptSearch")
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(NoteCopy.searchCounter(current: current + 1, total: total))
                    .font(.caption.monospacedDigit()).foregroundStyle(Color.muted).lineLimit(1).fixedSize()
                    .accessibilityIdentifier("searchCounter")
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Group {
                Button(NoteCopy.previousMatch, systemImage: "chevron.up", action: previous)
                Button(NoteCopy.nextMatch, systemImage: "chevron.down", action: next)
            }
            .labelStyle(.iconOnly).frame(width: HitTarget.minimum, height: HitTarget.minimum).disabled(total == 0)
            Button(NoteCopy.closeSearch, systemImage: "xmark.circle.fill", action: close)
                .labelStyle(.iconOnly).foregroundStyle(Color.muted)
                .frame(width: HitTarget.minimum, height: HitTarget.minimum)
        }
        .padding(.leading, 14).padding(.vertical, 2)
        .cardBackground(radius: Radius.field, outlined: false)
        .onAppear { if query.isEmpty { focused = true } }
        .onChange(of: total == 0 ? -1 : current) { _, _ in
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            AccessibilityNotification.Announcement(NoteCopy.searchCounter(current: current + 1, total: total)).post()
        }
    }
}
