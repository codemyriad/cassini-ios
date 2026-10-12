import SwiftUI
import CassiniNotebook

/// The card of the recording in progress.
struct ActiveRecordingCard: View {
    @Environment(RecordingStore.self) private var recording
    @Environment(Router.self) private var router
    var body: some View {
        let paused = recording.state.activeRecording?.pause != nil
        Button { router.presentRecording() } label: {
            HStack(spacing: 14) {
                Image(systemName: paused ? "pause.circle" : "waveform.circle.fill").font(.title).foregroundStyle(Color.ember)
                VStack(alignment: .leading, spacing: 4) {
                    Text(paused ? "Recording paused" : "Recording in progress").font(.headline)
                    Text("Tap to return").font(.caption).foregroundStyle(Color.muted)
                }
                Spacer(); Text(TimeText.clock(recording.state.activeRecording?.elapsed ?? 0)).font(.body.monospacedDigit())
            }.padding(18).cardBackground(outlined: false)
        }.buttonStyle(.plain)
    }
}

/// Import and Record, pinned to the bottom of the Library.
struct CaptureBar: View {
    @Environment(RecordingStore.self) private var recording
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Binding var importing: Bool
    var body: some View {
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 18))
        let active = recording.state.isActive
        layout {
            Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down").font(.subheadline.weight(.semibold)).frame(minWidth: 88, minHeight: 52) }
            Button { Task { await recording.start() } } label: {
                Label(active ? "Return to recording" : "Record", systemImage: active ? "waveform" : "mic.fill")
            }.buttonStyle(PrimaryButtonStyle()).disabled(recording.isBusy).accessibilityIdentifier("recordButton")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1).padding(.horizontal, Spacing.gutter).padding(.vertical, 14)
        .frame(maxWidth: ReadableWidth.library).frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}
