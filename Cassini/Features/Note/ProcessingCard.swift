import SwiftUI
import CassiniNotebook

struct ProcessingCard: View {
    let note: Note
    @Environment(ProcessingStore.self) private var processing
    var body: some View {
        let running = processing.state.isRunning(note.id) ? processing.state.running : nil
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(note.status == .queued ? "Waiting to transcribe" : running?.phase.message ?? ProcessingPhase.starting.message).font(.subheadline.weight(.medium))
                Spacer()
                Button("Cancel") { processing.cancel(note.id) }.font(.subheadline)
            }
            if note.status == .transcribing { ProgressView(value: running?.fraction).tint(.ember) }
            Text("Your audio is saved. Transcription happens on this device. Keep Cassini open for long recordings.").font(.caption).foregroundStyle(Color.muted)
        }.padding(Spacing.card).cardBackground(radius: 18, outlined: false)
    }
}

extension ProcessingPhase {
    var message: String {
        switch self {
        case .starting: "Preparing…"
        case .downloading: "Preparing speech model…"
        case .transcribing: "Transcribing on this device…"
        case .preparingSpeakers: "Preparing speaker models…"
        case .identifyingSpeakers, .matching: "Identifying speakers on this device…"
        case .saving: "Saving…"
        case .stopping: "Stopping…"
        }
    }
}
