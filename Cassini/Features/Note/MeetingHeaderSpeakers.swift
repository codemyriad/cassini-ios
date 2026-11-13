import SwiftUI
import CassiniNotebook

/// Names use the transcript's presentation, including speakers whose words only occur in inline replies.
struct MeetingHeaderSpeakers: View {
    let speakers: [TranscriptSpeaker]
    let nameSpeaker: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 16, rowSpacing: 6) {
            ForEach(speakers) { speaker in
                if speaker.id == NoteTranscripts.draftOneVoice {
                    label(speaker)
                } else {
                    Button { nameSpeaker(speaker.id) } label: { label(speaker) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(NoteCopy.nameThisSpeaker)
                        .accessibilityIdentifier("headerSpeaker-\(speaker.id)")
                }
            }
        }
        .accessibilityIdentifier("meetingSpeakers")
    }

    private func label(_ speaker: TranscriptSpeaker) -> some View {
        HStack(spacing: 6) {
            Circle().fill(speaker.tint.color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(NoteCopy.speakerName(speaker.name)).font(.subheadline).foregroundStyle(Color.ink)
                .underline(!speaker.name.isNamed, color: Color.muted.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if speaker.auto {
                Text(NoteCopy.auto).font(.caption2.weight(.medium)).foregroundStyle(Color.muted)
                    .padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.line, lineWidth: 1))
            }
        }
        .frame(minHeight: HitTarget.minimum, alignment: .leading)
        .contentShape(Rectangle())
    }
}
