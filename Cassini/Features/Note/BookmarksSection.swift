import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The note's marked moments (an iOS extra), folded under their count: each seeks to its moment, and can be removed.
struct BookmarksSection: View {
    let note: Note
    @Binding var isExpanded: Bool
    let model: NoteScreenModel

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 4) {
                ForEach(note.bookmarks) { bookmark in
                    HStack {
                        Button { model.seek(bookmark.time) } label: {
                            HStack {
                                Text(TimeText.clock(bookmark.time)).monospacedDigit().foregroundStyle(Color.accentInk)
                                Text(NoteCopy.bookmarkLabel(bookmark)).foregroundStyle(Color.ink)
                                Spacer()
                            }
                            .padding(.vertical, 10).frame(minHeight: HitTarget.minimum)
                        }
                        .buttonStyle(.plain)
                        Button(NoteCopy.removeBookmark, systemImage: "minus.circle") {
                            model.removeBookmark(bookmark.id)
                        }
                        .labelStyle(.iconOnly).frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(NoteCopy.markedMoments(note.bookmarks.count), systemImage: "bookmark").font(.subheadline.weight(.medium))
        }
    }
}
