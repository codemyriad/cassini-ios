import CassiniCore
import Foundation

extension ExportTranscript {
    /// The speaker id of passages without a speaker: those the user set to no speaker, and those of notes stored
    /// before D59 (read as stored, D51). The sealed document uses the same id.
    public static let unassignedSpeaker = "unassigned"

    /// The export of `note`'s current transcript, or of `version` when one is given. Labels are the speakers' names
    /// as the note shows them; `unassignedLabel` is used only when no stored unassigned-speaker label exists.
    ///
    /// A timed word whose text holds several words gives one word per part, each with the word's range. A passage
    /// without word timing (one edited by hand) gives one word per part too, its span shared out among them
    /// (`untimedWords`), so the cue rules cut it like a timed passage.
    public init(note: Note, version: TranscriptVersion? = nil, unassignedLabel: String) {
        let segments = version?.segments ?? note.transcript
        let speakers = version?.speakers ?? note.speakers ?? []
        var labels = Dictionary(speakers.map { ($0.byteID, $0.name) }, uniquingKeysWith: { first, _ in first })
        if labels[Data(Self.unassignedSpeaker.utf8)] == nil { labels[Data(Self.unassignedSpeaker.utf8)] = unassignedLabel }
        var legacyLabels = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if legacyLabels[Self.unassignedSpeaker] == nil { legacyLabels[Self.unassignedSpeaker] = unassignedLabel }
        self.init(title: note.title, durationMs: Self.ms(note.duration), words: segments.flatMap(Self.words), labels: legacyLabels,
                  endsBoundedByAudio: !segments.isEmpty && segments.allSatisfy { $0.wordEndsBoundedByAudio == true }, labelsByID: labels)
    }

    private static func words(of segment: TranscriptSegment) -> [Word] {
        let speaker = segment.speakerID ?? unassignedSpeaker
        if segment.words.isEmpty {
            return untimedWords(parts(segment.text), speaker: speaker, startMs: ms(segment.start), endMs: ms(segment.end))
        }
        return segment.words.flatMap { word in
            parts(word.text).map { Word(speaker, ms(word.start), ms(word.end), $0,
                                        lowConfidenceSpeaker: word.lowConfidenceSpeaker == true) }
        }
    }

    /// `texts` over `startMs..<endMs`, each word's share of the span in proportion to its UTF-16 length. The ranges
    /// follow each other without overlapping: a word ends where the next one starts.
    static func untimedWords(_ texts: [String], speaker: String, startMs: Int64, endMs: Int64) -> [Word] {
        let span = max(0, endMs - startMs)
        let total = Int64(texts.reduce(0) { $0 + $1.utf16.count })
        guard total > 0 else { return [] }
        var words: [Word] = []
        var before: Int64 = 0
        for text in texts {
            let after = before + Int64(text.utf16.count)
            words.append(Word(speaker, startMs + span * before / total, startMs + span * after / total, text))
            before = after
        }
        return words
    }

    private static func parts(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    static func ms(_ seconds: Double) -> Int64 { seconds.isFinite ? Int64((max(0, seconds) * 1000).rounded()) : 0 }
}
