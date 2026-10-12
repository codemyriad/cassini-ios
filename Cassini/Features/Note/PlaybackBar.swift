import SwiftUI
import CassiniNotebook

struct PlaybackBar: View {
    let note: Note
    /// Called after a bookmark is added, to show the bookmarks.
    let addBookmark: () -> Void
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let position = playback.state.noteID == note.id ? playback.state.position : 0
        VStack(spacing: 7) {
            ZStack {
                Waveform(levels: note.waveform, progress: position / max(1, note.duration)).frame(height: 32).padding(.horizontal, 2)
                Slider(value: Binding(get: { position }, set: { playback.seek($0) }), in: 0...max(0.1, note.duration))
                    .tint(.ember).accessibilityLabel("Playback position").accessibilityValue(TimeText.clock(position))
            }.frame(height: 36)
            HStack {
                Text(TimeText.clock(position))
                Spacer()
                Text("−" + TimeText.clock(max(0, note.duration - position)))
            }.font(.caption2.monospacedDigit()).foregroundStyle(Color.muted)
            HStack {
                Menu {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { playback.rate = rate } }
                } label: { Text("\(playback.rate.formatted())×").font(.subheadline.weight(.semibold)).frame(width: 48, height: 48) }.accessibilityLabel("Playback speed")
                Spacer()
                Button { playback.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2).frame(width: 48, height: 48) }.accessibilityLabel("Back 15 seconds")
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(Color.paper)
                        .frame(width: 58, height: 58).background(Color.ink, in: Circle())
                }.accessibilityLabel(playback.state.isPlaying ? "Pause playback" : "Play recording").accessibilityIdentifier("playButton")
                Button { playback.skip(15) } label: { Image(systemName: "goforward.15").font(.title2).frame(width: 48, height: 48) }.accessibilityLabel("Forward 15 seconds")
                Spacer()
                Button {
                    let time = position, bookmark = UUID()
                    library.update(note.id) { $0.addBookmark(at: time, id: bookmark) }
                    addBookmark()
                } label: { Image(systemName: "bookmark").font(.title3).frame(width: 48, height: 48) }.accessibilityLabel("Mark this moment")
            }.foregroundStyle(Color.ink)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1).padding(.horizontal, Spacing.gutter).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: ReadableWidth.note).frame(maxWidth: .infinity).background(.regularMaterial)
    }
}
