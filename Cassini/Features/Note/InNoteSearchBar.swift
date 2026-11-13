import SwiftUI

/// In-note Find: match navigation wraps and Close leaves the current meeting open.
struct InNoteSearchBar: View {
    @Binding var query: String
    let current: Int
    let total: Int
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 0) {
                        searchField.frame(minHeight: HitTarget.minimum)
                        HStack(spacing: 6) {
                            counter
                            Spacer(minLength: 0)
                            navigation
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        searchField
                        counter
                        navigation
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(minHeight: HitTarget.minimum)
            .meetingGlass(cornerRadius: 22)

            Button(NoteCopy.closeSearch, systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                .meetingGlass(cornerRadius: 22)
        }
        .onAppear { if query.isEmpty { focused = true } }
        .onChange(of: total == 0 ? -1 : current) { _, _ in
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            AccessibilityNotification.Announcement(NoteCopy.searchCounter(current: current + 1, total: total)).post()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(Color.muted)
                .accessibilityHidden(true)
            TextField(MeetingPhase1Copy.findPlaceholder, text: $query,
                      prompt: Text(MeetingPhase1Copy.findPlaceholder).foregroundStyle(Color.ink3))
                .font(.body)
                .autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search)
                .focused($focused)
                .onSubmit(next)
                .accessibilityIdentifier("transcriptSearch")
        }
    }

    @ViewBuilder private var counter: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(NoteCopy.searchCounter(current: current + 1, total: total))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.muted)
                .lineLimit(dynamicType.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: !dynamicType.isAccessibilitySize, vertical: true)
                .accessibilityIdentifier("searchCounter")
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            matchButton(NoteCopy.previousMatch, symbol: "chevron.up", action: previous)
            matchButton(NoteCopy.nextMatch, symbol: "chevron.down", action: next)
        }
        .disabled(total == 0)
    }

    private func matchButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: HitTarget.minimum, height: HitTarget.minimum)
    }
}
