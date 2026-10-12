import SwiftUI
import CassiniNotebook

/// "Transcription paused · N waiting" with Continue, while a hold keeps queued notes from starting.
struct QueueHeldBanner: View {
    @Environment(ProcessingStore.self) private var processing

    var body: some View {
        let state = processing.state
        if state.hold != nil, !state.queue.isEmpty, state.running == nil {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "pause.circle").foregroundStyle(Tone.info.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription paused · \(state.queue.count) waiting", tableName: "Transcription")
                        .font(.subheadline.weight(.semibold))
                    Text("Continue when you’re ready.", tableName: "Transcription").font(.subheadline).foregroundStyle(Color.muted)
                }
                Spacer(minLength: 0)
                Button { processing.continueQueue() } label: { Text("Continue", tableName: "Transcription") }
                    .font(.subheadline.weight(.semibold)).tint(.ember).frame(minHeight: HitTarget.minimum)
            }
            .foregroundStyle(Color.ink)
            .padding(16)
            .background(Tone.info.background, in: RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityElement(children: .contain)
        }
    }
}
