import Foundation

/// One transcript word as the Note screen reads it: its stored text, when it starts and ends
/// in the audio, its speaker (nil for a passage without one) and the passage it came from.
public struct TranscriptWord: Hashable, Sendable {
    public var speaker: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Legacy source hint, retained for callers; the viewer pipeline decides separators between stored atoms.
    public var lowConfidenceSpeaker: Bool
    public var spaceBefore: Bool
    /// The passage the word belongs to; nil for draft words.
    public var segmentID: UUID?

    public init(speaker: String?, start: TimeInterval, end: TimeInterval, text: String, spaceBefore: Bool = true,
                segmentID: UUID? = nil, lowConfidenceSpeaker: Bool = false) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
        self.spaceBefore = spaceBefore; self.segmentID = segmentID
        self.lowConfidenceSpeaker = lowConfidenceSpeaker
    }
}

/// One reading row of the shared turn model. The source word array stays in canonical order; `wordIndices`
/// and the members map the reading layout back to those original atoms for identity and playback.
public struct TranscriptTurn: Hashable, Sendable {
    public var speaker: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [TranscriptWord]
    public var wordIndices: [Int]
    public var continuation: Bool
    public var over: [String]
    public var crosstalk: Bool
    public var members: [TurnModel.Member]

    /// Stored words, with interjections at their model seam. Callers with display labels can render `members` instead.
    public var text: String {
        TranscriptTurns.text(of: members) { $0 ?? "Unknown speaker" }
    }
}

/// Adapters to the same turn model used by the note, preview and text export.
public enum TranscriptTurns {
    public static func rows(of words: [TranscriptWord], endsBoundedByAudio: Bool = false) -> [TurnModel.Row] {
        rows(ofModelWords: words.map {
            TurnModel.Word(speaker: $0.speaker, startMs: ($0.start * 1000).rounded(), endMs: ($0.end * 1000).rounded(),
                           text: $0.text, lowConfidenceSpeaker: $0.lowConfidenceSpeaker)
        }, endsBoundedByAudio: endsBoundedByAudio)
    }

    static func rows(ofModelWords source: [TurnModel.Word], endsBoundedByAudio: Bool) -> [TurnModel.Row] {
        var rawByCanonical: [String: Data] = [:]
        var hasCollision = false
        var values = source
        for word in values {
            if let id = word.speaker {
                let bytes = Data(id.utf8)
                if let previous = rawByCanonical[id], previous != bytes { hasCollision = true }
                else { rawByCanonical[id] = bytes }
            }
        }
        guard hasCollision else { return TurnModel.rows(of: values, endsBoundedByAudio: endsBoundedByAudio) }
        // The viewer's algorithms use String equality. Project all IDs to collision-free ASCII tokens only
        // when distinct UTF-8 identities would compare equal, then restore the exact IDs at the boundary.
        var tokens: [Data: String] = [:], originals: [String: String] = [:]
        for index in values.indices {
            guard let id = values[index].speaker else { continue }
            let key = Data(id.utf8)
            let token: String
            if let existing = tokens[key] { token = existing }
            else {
                token = "__cassini_byte_speaker_\(tokens.count)"
                tokens[key] = token; originals[token] = id
            }
            values[index].speaker = token
        }
        return TurnModel.rows(of: values, endsBoundedByAudio: endsBoundedByAudio).map { value in
            var row = value
            row.speaker = row.speaker.flatMap { originals[$0] }
            row.members = row.members.map { value in
                var member = value
                member.speaker = member.speaker.flatMap { originals[$0] }
                return member
            }
            row.over = row.over.map { originals[$0] ?? $0 }
            return row
        }
    }

    public static func of(_ words: [TranscriptWord], endsBoundedByAudio: Bool = false) -> [TranscriptTurn] {
        rows(of: words, endsBoundedByAudio: endsBoundedByAudio).map { row in
            let indices = row.members.flatMap(\.wordIndices)
            return TranscriptTurn(speaker: row.speaker, start: row.startMs / 1000, end: row.endMs / 1000,
                                  words: indices.map { words[$0] }, wordIndices: indices, continuation: row.continuation,
                                  over: row.over, crosstalk: row.crosstalk, members: row.members)
        }
    }

    /// The viewer's spacing of stored atoms. Word text is never rewritten and quotes are never paired.
    public static func text(of words: [TranscriptWord]) -> String {
        TurnModel.joinedText(words.map(\.text))
    }

    public static func text(of members: [TurnModel.Member], label: (String?) -> String) -> String {
        members.map { member in
            member.kind == .interjection ? "(\(label(member.speaker)): \(member.text))" : member.text
        }.joined(separator: " ")
    }
}

extension Note {
    /// The words of the shown transcript in order, each with its passage's speaker. A passage without word times is one
    /// word of its whole text.
    public var transcriptWords: [TranscriptWord] { transcript.transcriptWords }
}

extension Array where Element == TranscriptSegment {
    /// See `Note.transcriptWords`.
    public var transcriptWords: [TranscriptWord] {
        var words: [TranscriptWord] = []
        for segment in self {
            guard !segment.words.isEmpty else {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(TranscriptWord(speaker: segment.speakerID, start: segment.start, end: segment.end, text: text,
                                            segmentID: segment.id))
                continue
            }
            for word in segment.words {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(TranscriptWord(speaker: segment.speakerID, start: word.start, end: word.end, text: text,
                                            segmentID: segment.id, lowConfidenceSpeaker: word.lowConfidenceSpeaker == true))
            }
        }
        return words
    }
}
