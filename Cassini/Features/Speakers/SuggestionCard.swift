import SwiftUI
import CassiniEngine
import CassiniNotebook

/// "Is this **Luca**?" [Yes, Luca] [Not Luca], above the first passage of a placeholder speaker that a saved voice may
/// be. The header opens Name a speaker. Yes names the speaker and remembers its print in the voice; Not rejects the
/// voice for this speaker for good.
struct SuggestionCard: View {
    let suggestion: SpeakerSuggestion
    let ordinal: Int
    let model: NoteScreenModel
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.speakerTapped(suggestion.speakerID) } label: {
                HStack(spacing: 10) {
                    SpeakerAvatar(speaker: suggestion.label, ordinal: ordinal, size: 28)
                    Text(NoteCopy.speakerLabel(suggestion.label, id: suggestion.speakerID, ordinal: ordinal))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
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
            await model.answer(suggestion, yes: yes)
            busy = false
        }
    }
}
