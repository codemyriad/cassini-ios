import SwiftUI
import CassiniNotebook

struct TrashCard: View {
    let note: Note
    let deleteForever: () -> Void
    @Environment(TrashStore.self) private var trash
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.title).font(.headline)
            if let date = note.trashedAt {
                Text("Deleted \(date.formatted(date: .abbreviated, time: .omitted)) · \(trash.daysLeft(note)) days left").font(.caption).foregroundStyle(.secondary)
            }
            Text(TimeText.clock(note.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button("Restore", systemImage: "arrow.uturn.backward") { trash.restore(note.id) }.buttonStyle(.bordered)
                Spacer()
                Button("Delete forever", systemImage: "trash", role: .destructive, action: deleteForever).buttonStyle(.borderless)
            }
        }.padding(.vertical, 8)
    }
}
