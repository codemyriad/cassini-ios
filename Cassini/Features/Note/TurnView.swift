import SwiftUI
import CassiniNotebook

/// One passage: its time, its speaker, and words that play from where they were said.
struct TurnView: View {
    let noteID: UUID
    let segment: TranscriptSegment
    let query: String
    let isActive: Bool
    let edit: (TranscriptSegment) -> Void
    let seek: (TimeInterval) -> Void
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let playing = isActive && playback.state.isPlaying
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { seek(segment.start) } label: {
                    Text(TimeText.clock(segment.start)).font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(Color.ember).padding(.vertical, 6)
                }.accessibilityLabel("Play from \(TimeText.clock(segment.start))")
                if let speaker = segment.speaker { Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(Color.muted) }
                Spacer()
                if playing { Image(systemName: "waveform").font(.caption).foregroundStyle(Color.ember).accessibilityLabel("Now playing") }
            }
            Text(linkedText).font(.system(.body, design: .serif)).lineSpacing(7).foregroundStyle(Color.ink).tint(Color.ink)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "cassini", let time = Double(url.lastPathComponent) else { return .systemAction }
                    seek(time); return .handled
                })
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color.ember.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(alignment: .leading) { if isActive { RoundedRectangle(cornerRadius: 2).fill(Color.ember).frame(width: 3).padding(.vertical, 16) } }
        .contextMenu {
            Button("Edit passage", systemImage: "pencil") { edit(segment) }
            Button("Label speaker", systemImage: "person") { edit(segment) }
            Button("Mark this moment", systemImage: "bookmark") { addBookmark() }
            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = segment.text }
        }
        .accessibilityAction(named: "Edit passage") { edit(segment) }
        .accessibilityAction(named: "Mark this moment") { addBookmark() }
    }

    private func addBookmark() {
        let time = segment.start
        let bookmark = UUID()
        library.update(noteID) { $0.addBookmark(at: time, id: bookmark) }
    }

    private var linkedText: AttributedString {
        if segment.words.isEmpty {
            var result = AttributedString(segment.text)
            result.link = URL(string: "cassini://seek/\(segment.start)")
            if !query.isEmpty && segment.text.localizedStandardContains(query) { result.backgroundColor = Color.ember.opacity(0.15) }
            return result
        }
        let position = isActive && playback.state.isPlaying ? playback.state.position : nil
        var result = AttributedString()
        for word in segment.words {
            var part = AttributedString(word.text)
            part.link = URL(string: "cassini://seek/\(word.start)")
            let spoken = position.map { $0 >= word.start && $0 < word.end } ?? false
            if spoken || (!query.isEmpty && word.text.localizedStandardContains(query)) { part.backgroundColor = Color.ember.opacity(0.18) }
            result.append(part)
        }
        return result
    }
}
