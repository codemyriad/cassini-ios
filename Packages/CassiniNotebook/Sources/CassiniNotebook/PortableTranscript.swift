import Foundation
import CassiniCore

/// A verified, read-only projection of an imported Cassini document.
/// The source remains untouched, retaining every variant and extension.
public struct PortableTranscript: Sendable {
    public let title: String
    public let language: String
    public let duration: Double
    public let segments: [TranscriptSegment]

    public static func read(from url: URL) -> PortableTranscript? {
        let document = CassiniDocument.read(url)
        guard document.state == "ok", let transcript = document.selected()?.transcript else { return nil }
        var segments: [TranscriptSegment] = []
        var group: [Word] = []
        func flush() {
            guard let first = group.first else { return }
            let words = group.enumerated().map { index, word in
                TimedWord(text: word.text + (index == group.count - 1 ? "" : " "),
                          start: Double(word.startMs) / 1000, end: Double(word.endMs) / 1000)
            }
            segments.append(TranscriptSegment(text: group.map(\.text).joined(separator: " "),
                start: Double(first.startMs) / 1000, end: Double(group.map(\.endMs).max() ?? first.endMs) / 1000,
                speaker: document.speakerLabel(first.speaker) ?? first.speaker, words: words))
            group.removeAll(keepingCapacity: true)
        }
        // Preserve canonical word order, including overlapping speakers.
        for word in transcript.words {
            if let previous = group.last,
               previous.speaker != word.speaker || group.count >= 45 || word.startMs - previous.endMs > 2000 { flush() }
            group.append(word)
        }
        flush()
        let duration = (try? document.manifest?.object("meeting").number("durationMs")) ?? 0
        return PortableTranscript(title: document.title, language: transcript.language,
                                  duration: Double(duration) / 1000, segments: segments)
    }
}
