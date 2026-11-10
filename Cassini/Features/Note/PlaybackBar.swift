import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Read & listen player: the position slider over the waveform, the position and total duration, then back
/// 10 s, play/pause and forward 10 s, with the speed menu and the bookmark button (iOS extras) at the sides.
///
/// Dragging the slider moves only the slider and the times; the player seeks once, when the drag ends. VoiceOver reads
/// the slider as "Position", "11:44 of 23:50", and swipes move it by 10 s. The bar is one accessibility group,
/// "Playback".
struct PlaybackBar: View {
    let note: Note
    /// Mark this moment at a position: the bookmark, and the section that lists it open.
    let markMoment: (TimeInterval) -> Void
    @Environment(PlaybackStore.self) private var playback
    /// Where the slider is while it is dragged.
    @State private var dragging: TimeInterval?

    private var ours: Bool { playback.owns(note.id) }
    private var duration: TimeInterval { ours && playback.state.duration > 0 ? playback.state.duration : note.duration }
    private var position: TimeInterval { dragging ?? (ours ? playback.state.position : note.playbackPosition) }
    private var isPlaying: Bool { ours && playback.state.isPlaying }

    var body: some View {
        VStack(spacing: 7) {
            slider
            HStack {
                Text(TimeText.clock(position))
                Spacer()
                Text(TimeText.clock(duration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(Color.muted)
            .accessibilityHidden(true)
            controls
        }
        // Five buttons in a row: past AX1 they would not fit, so the bar stops growing there and shows the Large
        // Content Viewer instead (Android keeps the skip digits' size too).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1).accessibilityShowsLargeContentViewer()
        .padding(.horizontal, Spacing.gutter).padding(.top, 12).padding(.bottom, 8)
        // Opaque, so its text keeps its contrast over the transcript scrolling under it.
        .readableWidth().background(Color.paper).overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Playback", tableName: "Playback"))
        .accessibilityIdentifier("playbackBar")
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if let target = playback.seekProbe?.target {
                Text(verbatim: " ").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("uiTestState-playbackSeekTarget")
                    .accessibilityValue(Text(verbatim: String(target)))
            }
        }
        #endif
    }

    private var slider: some View {
        let range = 0...max(0.1, duration)
        return ZStack {
            Waveform(levels: note.waveform, progress: position / max(1, duration)).frame(height: 32).padding(.horizontal, 2)
            Slider(value: Binding(get: { min(position, range.upperBound) }, set: { dragging = $0 }), in: range) { editing in
                guard !editing, let target = dragging else { return }
                playback.seek(target)
                dragging = nil
            }
            .tint(.ember)
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Position", tableName: "Playback"))
        .accessibilityValue(Text(Self.spokenPosition(position, of: duration)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playback.seek(PlaybackSkip.step(from: position, forward: true, duration: duration))
            case .decrement: playback.seek(PlaybackSkip.step(from: position, forward: false, duration: duration))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("playbackPosition")
    }

    private var controls: some View {
        HStack {
            Menu {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button { playback.rate = rate } label: { Text(verbatim: "\(rate.formatted())×") }
                }
            } label: {
                Text(verbatim: "\(playback.rate.formatted())×").font(.subheadline.weight(.semibold)).frame(width: 48, height: 48)
            }
            .accessibilityLabel(Text("Playback speed", tableName: "Playback"))
            .accessibilityIdentifier("playbackSpeed")
            Spacer()
            Button { playback.skip(-PlaybackSkip.interval) } label: {
                Image(systemName: "gobackward.10").font(.title2).frame(width: 52, height: 52)
            }
            .accessibilityLabel(Text("Back 10 seconds", tableName: "Playback"))
            Button { playback.togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(Color.paper)
                    .frame(width: 64, height: 64).background(Color.ink, in: Circle())
            }
            .accessibilityLabel(isPlaying ? Text("Pause", tableName: "Playback") : Text("Play", tableName: "Playback"))
            .accessibilityValue(isPlaying ? Text("Playing", tableName: "Playback") : Text("Paused", tableName: "Playback"))
            .accessibilityIdentifier("playButton")
            Button { playback.skip(PlaybackSkip.interval) } label: {
                Image(systemName: "goforward.10").font(.title2).frame(width: 52, height: 52)
            }
            .accessibilityLabel(Text("Forward 10 seconds", tableName: "Playback"))
            .accessibilityIdentifier("skipForward")
            Spacer()
            Button { markMoment(position) } label: { Image(systemName: "bookmark").font(.title3).frame(width: 48, height: 48) }
            .accessibilityLabel(Text("Mark this moment", tableName: "Playback"))
        }
        .foregroundStyle(Color.ink)
    }

    /// "11:44 of 23:50".
    static func spokenPosition(_ position: TimeInterval, of duration: TimeInterval) -> String {
        let position = TimeText.clock(position), total = TimeText.clock(duration)
        return String(localized: "\(position) of \(total)", table: "Playback",
                      comment: "Accessibility value of the position slider: position of total duration, e.g. 11:44 of 23:50")
    }
}
