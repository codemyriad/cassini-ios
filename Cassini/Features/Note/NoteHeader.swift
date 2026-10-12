import SwiftUI
import CassiniNotebook

struct NoteHeader: View {
    let note: Note
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                StatusPill(status: note.status)
                Spacer()
                Text(note.createdAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.muted)
            }
            Text(note.title).font(.system(.largeTitle, design: .serif)).tracking(-0.7).foregroundStyle(Color.ink).textSelection(.enabled).accessibilityIdentifier("noteTitle")
            HStack(spacing: 16) {
                Label(TimeText.clock(note.duration), systemImage: "waveform")
                if note.wordCount > 0 { Text("\(note.wordCount.formatted()) words") }
                Text(locale.localizedString(forIdentifier: note.language) ?? note.language).lineLimit(1)
            }.font(.caption).foregroundStyle(Color.muted)
        }
    }
}
