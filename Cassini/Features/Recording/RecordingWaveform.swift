import SwiftUI
import CassiniNotebook

/// The Recording waveform: the last 7 s of microphone levels, 56 bars of 125 ms, oldest first. The newest 7 bars use
/// the fresh colour. Each new level is drawn as it comes, without animation. One image for VoiceOver.
struct RecordingWaveform: View {
    let levels: [Float]
    var isPaused = false
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 96

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let gap: CGFloat = 3
            let width = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            for (index, level) in levels.enumerated() {
                let barHeight = max(4, (CGFloat(min(1, max(0, level))) * (size.height - 4)).rounded())
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - barHeight) / 2, width: width, height: barHeight)
                let fresh = index >= count - WaveformBars.freshCount && !isPaused
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fresh ? .recordingAccent : .compatibilityWhite.opacity(0.28)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("Microphone level, last 7 seconds", tableName: "Recording"))
    }
}
