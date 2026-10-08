import CassiniCore
import SwiftUI

/** A run of consecutive words by one speaker; word order is canonical, so runs are never re-sorted. */
struct Paragraph: Identifiable {
    let id: Int
    let speaker: String
    let startMs: Int64
    let text: String

    static func from(_ words: [Word]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first else { return }
            paragraphs.append(Paragraph(id: paragraphs.count, speaker: first.speaker, startMs: first.startMs,
                                        text: current.map { $0.text }.joined(separator: " ")))
            current = []
        }
        for word in words {
            if let last = current.last, last.speaker != word.speaker || word.startMs - last.endMs > 2000 { flush() }
            current.append(word)
        }
        flush()
        return paragraphs
    }
}

struct NoteView: View {
    let url: URL
    @State private var document: CassiniDocument?

    var body: some View {
        ScrollView {
            if let doc = document {
                content(doc).padding()
            } else {
                ProgressView().padding(48)
            }
        }
        .background(Deck.ink.ignoresSafeArea())
        .navigationTitle(document?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let url = self.url
            document = await Task.detached(priority: .userInitiated) { CassiniDocument.read(url) }.value
        }
    }

    @ViewBuilder private func content(_ doc: CassiniDocument) -> some View {
        let transcript = doc.selected()?.transcript
        let paragraphs = Paragraph.from(transcript?.words ?? [])
        let speakers = Set(paragraphs.map { $0.speaker })
        VStack(alignment: .leading, spacing: 16) {
            Text(status(doc)).font(.caption.monospaced()).foregroundColor(doc.state == "ok" ? Deck.muted : Deck.warning)
            Text("note.transcript").font(.caption.monospaced()).tracking(1).foregroundColor(Deck.muted)
            if paragraphs.isEmpty {
                Text("note.no_transcript").foregroundColor(Deck.muted)
            }
            ForEach(paragraphs) { paragraph in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if speakers.count > 1 {
                            Text(doc.speakerLabel(paragraph.speaker) ?? paragraph.speaker).font(.caption.weight(.semibold)).foregroundColor(Deck.amber)
                        }
                        Text(clock(paragraph.startMs)).font(.caption.monospaced()).foregroundColor(Deck.muted)
                    }
                    Text(paragraph.text).font(.body).foregroundColor(Deck.paper).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func status(_ doc: CassiniDocument) -> String {
        switch doc.state {
        case "ok": return NSLocalizedString("note.state.ok", comment: "")
        case "unverified": return NSLocalizedString("note.state.unverified", comment: "")
        case "stale-audio": return NSLocalizedString("note.state.stale", comment: "")
        case "plain-audio": return NSLocalizedString("note.state.plain", comment: "")
        default: return NSLocalizedString("note.state.invalid", comment: "")
        }
    }

    private func clock(_ ms: Int64) -> String {
        let s = ms / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
