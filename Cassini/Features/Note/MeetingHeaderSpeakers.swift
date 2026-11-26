import SwiftUI
import CassiniNotebook

/// Names use the transcript's presentation, including speakers whose words only occur in inline replies.
struct MeetingHeaderSpeakers: View {
    let speakers: [TranscriptSpeaker]
    let nameSpeaker: (String) -> Void
    var openSpeakers: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        if dynamicType.isAccessibilitySize, let openSpeakers, speakers.contains(where: { $0.id != NoteTranscripts.draftOneVoice }) {
            Button(action: openSpeakers) {
                HStack(spacing: 4) {
                    Text(NoteCopy.speakerCount(speakers.count))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ink)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.muted)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: HitTarget.minimum, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, -8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("headerSpeakersCollapsed")
        } else {
            FlowLayout(spacing: 16, rowSpacing: 6) {
                ForEach(speakers, id: \.byteID) { speaker in
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
        }
    }

    private func label(_ speaker: TranscriptSpeaker) -> some View {
        HStack(spacing: 6) {
            Circle().fill(speaker.tint.color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(NoteCopy.speakerName(speaker.name)).font(.subheadline).foregroundStyle(speaker.tint.color)
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
        .padding(.vertical, -11)
    }
}
