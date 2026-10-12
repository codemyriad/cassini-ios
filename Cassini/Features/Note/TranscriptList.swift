import SwiftUI
import CassiniNotebook

/// The transcript, passage by passage. `suggestion` puts a card above a passage, e.g. "Is this Luca?".
struct TranscriptList: View {
    let note: Note
    let query: String
    let activeSegment: UUID?
    @Binding var followPlayback: Bool
    let showSpeakers: () -> Void
    let edit: (TranscriptSegment) -> Void
    let seek: (TimeInterval) -> Void
    var suggestion: (TranscriptSegment) -> AnyView? = { _ in nil }

    private var matching: [TranscriptSegment] {
        note.transcript.filter { query.isEmpty || $0.text.localizedStandardContains(query) || ($0.speaker?.localizedStandardContains(query) ?? false) }
    }

    var body: some View {
        HStack {
            Text("TRANSCRIPT").font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(Color.muted).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { followPlayback.toggle() } label: {
                Label(followPlayback ? "Following" : "Follow audio", systemImage: "text.line.first.and.arrowtriangle.forward")
            }.font(.caption).accessibilityValue(followPlayback ? "On" : "Off")
        }
        Button(action: showSpeakers) { Label("Speakers · \(note.speakers?.count ?? 0)", systemImage: "person.2") }.accessibilityIdentifier("speakersButton")
        LazyVStack(alignment: .leading, spacing: 8) {
            let segments = matching
            ForEach(segments) { segment in
                if let card = suggestion(segment) { card }
                TurnView(noteID: note.id, segment: segment, query: query, isActive: activeSegment == segment.id, edit: edit, seek: seek)
                    .id(segment.id)
            }
            if !query.isEmpty && segments.isEmpty { ContentUnavailableView.search(text: query) }
        }
        Text("Tap a word to listen from that moment. Touch and hold a passage to edit it or label its speaker.")
            .font(.caption).foregroundStyle(Color.muted).padding(.top, 8)
    }
}

struct TranscriptEmptyState: View {
    let note: Note
    let requestTranscription: () -> Void
    @Environment(RecordingStore.self) private var recording
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: note.status == .ready ? "text.bubble" : "text.alignleft").font(.system(size: 30, weight: .light)).foregroundStyle(Color.ember)
            Text(note.status == .ready ? "No speech found" : "Let your recording become words.").font(.system(.title2, design: .serif)).multilineTextAlignment(.center)
            Text(note.status == .ready ? "Try a different language or check that voices are audible in the recording." : "A searchable transcript, with every passage connected to the original audio.")
                .font(.subheadline).foregroundStyle(Color.muted).multilineTextAlignment(.center)
            if note.status != .transcribing && note.status != .queued {
                Button(action: requestTranscription) { Label(note.status == .failed ? "Try again" : "Transcribe", systemImage: "text.badge.waveform") }
                    .buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 290).disabled(recording.finishingNoteID == note.id)
            }
        }.padding(.vertical, 40).frame(maxWidth: .infinity)
    }
}
