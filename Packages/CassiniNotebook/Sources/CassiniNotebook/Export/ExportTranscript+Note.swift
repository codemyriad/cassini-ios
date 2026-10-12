import CassiniCore
import Foundation

extension ExportTranscript {
    /// The speaker id of passages no speaker was found for; the sealed document uses the same id.
    public static let unassignedSpeaker = "unassigned"

    /// The export of `note`'s current transcript, or of `version` when one is given. Labels are the speakers' names
    /// as the note shows them; passages without a speaker are labelled `unassignedLabel`.
    ///
    /// A timed word whose text holds several words gives one word per part, each with the word's range. A passage
    /// without word timing (one edited by hand) is one word with the passage's text and range, so its subtitle keeps
    /// the passage's span instead of cues that share one start.
    public init(note: Note, version: TranscriptVersion? = nil, unassignedLabel: String) {
        let segments = version?.segments ?? note.transcript
        let speakers = version?.speakers ?? note.speakers ?? []
        var labels = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        labels[Self.unassignedSpeaker] = unassignedLabel
        self.init(title: note.title, durationMs: Self.ms(note.duration), words: segments.flatMap(Self.words), labels: labels)
    }

    private static func words(of segment: TranscriptSegment) -> [Word] {
        let speaker = segment.speakerID ?? unassignedSpeaker
        if segment.words.isEmpty {
            let text = parts(segment.text).joined(separator: " ")
            return text.isEmpty ? [] : [Word(speaker, ms(segment.start), ms(segment.end), text)]
        }
        return segment.words.flatMap { word in
            parts(word.text).map { Word(speaker, ms(word.start), ms(word.end), $0) }
        }
    }

    private static func parts(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    static func ms(_ seconds: Double) -> Int64 { seconds.isFinite ? Int64((max(0, seconds) * 1000).rounded()) : 0 }
}
