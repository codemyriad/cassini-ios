import SwiftUI
import CassiniEngine
import CassiniNotebook

/// "Is this **Luca**?" [Yes, Luca] [Not Luca], above the first passage of a placeholder speaker that a saved voice may
/// be in reading mode. The header opens Name a speaker. Yes names the speaker and remembers its print in the voice; Not
/// rejects the voice for this speaker for good.
struct SuggestionCard: View {
    let suggestion: SpeakerSuggestion
    let ordinal: Int
    let tint: SpeakerTint
    let model: NoteScreenModel
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.speakerTapped(suggestion.speakerID) } label: {
                HStack(spacing: 10) {
                    SpeakerAvatar(name: suggestion.label, tint: tint, size: 28)
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
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.onAccent)
                    .accessibilityIdentifier("suggestionYes")
                Button(SpeakersCopy.not(suggestion.voiceName)) { answer(yes: false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("suggestionNo")
            }
            .tint(.accentStrong)
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

/// Compact inline speaker-match prompt under a live draft turn's speaker header (L-45): `"Is this **Luca**?"` with
/// separate `No` and `Yes` 44×44pt targets carrying full spoken names (`"Not Luca"`, `"Yes, Luca"`).
struct CompactSuggestionRow: View {
    let suggestion: SpeakerSuggestion
    let answer: (SpeakerSuggestion, Bool) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    questionText
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        noButton
                        yesButton
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
            } else {
                HStack(spacing: 4) {
                    questionText
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    noButton
                    yesButton
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.neutralTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compactSuggestion-\(suggestion.speakerID)")
    }

    private var questionText: some View {
        Text(Self.question(suggestion.voiceName))
            .font(.subheadline)
            .foregroundStyle(Color.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var noButton: some View {
        Button { answer(suggestion, false) } label: {
            Text(MeetingPhase1Copy.speakerSuggestionNo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpeakersCopy.not(suggestion.voiceName))
        .accessibilityInputLabels([MeetingPhase1Copy.speakerSuggestionNo, SpeakersCopy.not(suggestion.voiceName)])
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("suggestionNo")
    }

    private var yesButton: some View {
        Button { answer(suggestion, true) } label: {
            Text(MeetingPhase1Copy.speakerSuggestionYes)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.onAccent)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Color.accentStrong, in: Capsule())
                .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpeakersCopy.yes(suggestion.voiceName))
        .accessibilityInputLabels([MeetingPhase1Copy.speakerSuggestionYes, SpeakersCopy.yes(suggestion.voiceName)])
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("suggestionYes")
    }

    static func question(_ name: String) -> AttributedString {
        var bold = AttributedString(name)
        bold.inlinePresentationIntent = .stronglyEmphasized
        let full = MeetingPhase1Copy.speakerSuggestion(name: name)
        guard let range = full.range(of: name) else { return AttributedString(full) }
        return AttributedString(full[..<range.lowerBound]) + bold + AttributedString(full[range.upperBound...])
    }
}
