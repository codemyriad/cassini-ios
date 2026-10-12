import SwiftUI
import CassiniNotebook

struct NoteHeader: View {
    let note: Note
    /// Shows or hides the trust banner of a note from a Cassini document.
    var toggleTrust: () -> Void = {}
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                StatusPill(status: note.status)
                if let trust = DocumentTrust.of(note) { DocumentTrustChip(trust: trust, toggle: toggleTrust) }
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
