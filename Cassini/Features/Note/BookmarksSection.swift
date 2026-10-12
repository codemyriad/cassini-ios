import SwiftUI
import CassiniNotebook

struct BookmarksSection: View {
    let note: Note
    @Binding var isExpanded: Bool
    let seek: (TimeInterval) -> Void
    @Environment(LibraryStore.self) private var library
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 4) {
                ForEach(note.bookmarks) { bookmark in
                    HStack {
                        Button { seek(bookmark.time) } label: {
                            HStack { Text(TimeText.clock(bookmark.time)).monospacedDigit().foregroundStyle(Color.ember); Text(bookmark.label).foregroundStyle(Color.ink); Spacer() }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Button("Remove bookmark", systemImage: "minus.circle") {
                            let id = bookmark.id
                            library.update(note.id) { $0.bookmarks.removeAll { $0.id == id } }
                        }.labelStyle(.iconOnly).frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                    }.font(.subheadline)
                }
            }.padding(.top, 8)
        } label: {
            Label("\(note.bookmarks.count) marked \(note.bookmarks.count == 1 ? "moment" : "moments")", systemImage: "bookmark").font(.subheadline.weight(.medium))
        }
    }
}
