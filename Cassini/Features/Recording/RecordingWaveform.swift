import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Observe meter samples here, never in the screen's layout, title or controls.
struct LiveRecordingWaveform: View {
    let screen: RecordingScreenModel
    var body: some View {
        RecordingWaveform(bars: screen.controller.bars, isPaused: screen.phase != .recording)
    }
}

/// One image for VoiceOver. Inactive, paused and Reduce Motion views contain no animation timeline at all.
struct RecordingWaveform: View {
    let bars: WaveformBars
    var isPaused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 96

    var body: some View {
        Group {
            if WaveformAnimation.animates(isPaused: isPaused, reduceMotion: reduceMotion, isActive: scenePhase == .active) {
                AnimatedRecordingWaveform(bars: bars)
            } else {
                RecordingWaveformCanvas(frame: WaveformAnimation.still(bars), isPaused: isPaused)
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("Microphone level, last 7 seconds", tableName: "Recording"))
    }
}

private struct AnimatedRecordingWaveform: View {
    let bars: WaveformBars
    @State private var motion: WaveformAnimation

    init(bars: WaveformBars) {
        self.bars = bars
        _motion = State(initialValue: WaveformAnimation(bars: bars, at: ProcessInfo.processInfo.systemUptime))
    }

    var body: some View {
        TimelineView(.animation) { _ in
            RecordingWaveformCanvas(frame: motion.frame(at: ProcessInfo.processInfo.systemUptime), isPaused: false)
        }
        .onChange(of: bars) { _, next in motion.update(next, at: ProcessInfo.processInfo.systemUptime) }
    }
}

private struct RecordingWaveformCanvas: View {
    let frame: WaveformAnimation.Frame
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let count = WaveformBars.count
            let gap: CGFloat = 3
            let width = max(1, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))
            var freshPath = Path(), historyPath = Path()
            // The two trailing baseline bars enter from outside the clip during fractional scrolling.
            for index in 0..<(count + 2) {
                let barHeight = frame.height(at: index, in: size.height)
                let rect = CGRect(x: (CGFloat(index) - frame.offset) * (width + gap),
                                  y: (size.height - barHeight) / 2, width: width, height: barHeight)
                let fresh = index >= count - WaveformBars.freshCount && !isPaused
                if fresh { freshPath.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2)) }
                else { historyPath.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2)) }
            }
            context.fill(historyPath, with: .color(Color.recordingSecondary))
            context.fill(freshPath, with: .color(Color.recordingAccent))
        }
    }
}
