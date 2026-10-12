import CassiniCore
import Foundation

/// Whether a transcript still fits the word body of a Cassini document (`WordBodyBudget`), counted the way an export
/// writes it: one item per word, each with a speaker id as long as the ones the speaker step gives.
public enum TranscriptBudget {
    /// As long as a speaker id after analysis: a UUID prefix, `_` and the analyzer's own id.
    static let speakerID = String(repeating: "0", count: 40)

    /// The most body bytes one transcript may have.
    public static let maxBytes = WordBodyBudget.maxBytes

    public static func bytes(_ segments: [TranscriptSegment], language: String = "") -> Int64 {
        let words = segments.flatMap(\.draftWords).map { Word(speakerID, $0.startMs, $0.endMs, $0.text) }
        return WordBodyBudget.bytes(words, language: language)
    }

    public static func fits(_ segments: [TranscriptSegment], language: String = "",
                            maxBytes: Int64 = TranscriptBudget.maxBytes) -> Bool {
        bytes(segments, language: language) <= maxBytes
    }
}
