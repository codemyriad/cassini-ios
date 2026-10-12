import SwiftUI
import CassiniNotebook

/// "Is this **Luca**?" [Yes, Luca] [Not Luca], above the first passage of a placeholder speaker that a saved voice may
/// be. The header opens Name a speaker. Yes names the speaker and remembers its print in the voice; Not rejects the
/// voice for this speaker for good.
struct SuggestionCard: View {
    let noteID: UUID
    let suggestion: SpeakerSuggestion
    let ordinal: Int
    let nameSpeaker: (String) -> Void
    @Environment(VoicesStore.self) private var voices
    @Environment(ErrorPresenter.self) private var errors
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { nameSpeaker(suggestion.speakerID) } label: {
                HStack(spacing: 10) {
                    SpeakerAvatar(speaker: suggestion.label, ordinal: ordinal, size: 28)
                    Text(suggestion.label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text(TimeText.clock(suggestion.start)).font(.caption.monospacedDigit()).foregroundStyle(Color.muted)
                    Spacer()
                }.frame(minHeight: HitTarget.minimum).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(SpeakersCopy.nameThisSpeaker)
            Text(SpeakersCopy.suggestion(suggestion.voiceName)).font(.body).foregroundStyle(Color.ink)
            HStack(spacing: 10) {
                Button(SpeakersCopy.yes(suggestion.voiceName)) { answer(yes: true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("suggestionYes")
                Button(SpeakersCopy.not(suggestion.voiceName)) { answer(yes: false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("suggestionNo")
            }
            .tint(.ember)
            .disabled(busy)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: Radius.control)
    }

    private func answer(yes: Bool) {
        busy = true
        Task {
            do throws(VoicesStore.SaveFailure) {
                if yes { try await voices.accept(suggestion, noteID: noteID) } else { try await voices.reject(suggestion, noteID: noteID) }
            } catch {
                errors.present(error.message)
            }
            busy = false
        }
    }
}
