import SwiftUI
import CassiniNotebook

struct NoteRow: View {
    @Environment(ProcessingStore.self) private var processing
    @Environment(\.dynamicTypeSize) private var dynamicType
    let note: Note
    var query = ""

    var body: some View {
        let rowLayout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        VStack(alignment: .leading, spacing: 13) {
            rowLayout {
                Text(note.title).font(.system(.title3, design: .serif, weight: .medium)).foregroundStyle(Color.ink).lineLimit(2)
                if !dynamicType.isAccessibilitySize { Spacer(minLength: 4) }
                HStack {
                    if note.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.ember).accessibilityLabel("Starred") }
                    Text(TimeText.clock(note.duration)).font(.caption.monospacedDigit()).foregroundStyle(Color.muted).padding(.top, 4)
                }.fixedSize()
            }
            if !note.transcript.isEmpty { Text(note.preview(matching: query)).font(.subheadline).foregroundStyle(Color.muted).lineLimit(2).lineSpacing(3) }
            rowLayout {
                Text(note.createdAt, style: .time).font(.caption).foregroundStyle(Color.muted)
                StatusPill(status: note.status)
                if !dynamicType.isAccessibilitySize { Spacer() }
                if !note.bookmarks.isEmpty { Label("\(note.bookmarks.count)", systemImage: "bookmark.fill").font(.caption2).foregroundStyle(Color.muted) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Color.muted)
            }
            if note.status == .transcribing {
                ProgressView(value: processing.state.isRunning(note.id) ? processing.state.running?.fraction : nil).tint(.ember)
            }
        }
        .padding(19).frame(maxWidth: .infinity, alignment: .leading).cardBackground()
        .accessibilityElement(children: .combine)
    }
}
