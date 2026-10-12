import CryptoKit
import Foundation

/// One stretch of time in which a diarizer heard one speaker.
public struct SpeakerTurn: Hashable, Sendable {
    public var speakerID: String
    public var start: Double
    public var end: Double
    public init(speakerID: String, start: Double, end: Double) { self.speakerID = speakerID; self.start = start; self.end = end }

    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
}

/// Puts a speaker analysis onto the words of a transcript without changing their text or their clock.
///
/// Each word goes to the speaker whose turns overlap it most, counting a speaker's overlapping turns once; a word
/// between turns goes to the nearest turn. Ties go to the speaker whose turn comes first. A passage spoken by one
/// speaker keeps its id and its text; a passage that several speakers share is split, the first piece keeping the
/// passage id and each later piece an id derived from it, so running the same attribution again gives the same ids.
public enum SpeakerAttribution {
    /// `turns` and `prints` with every speaker id put in a namespace of its own, so that each analysis of a note
    /// has speakers no earlier analysis had and earlier versions keep theirs.
    public static func namespaced(turns: [SpeakerTurn], prints: [SpeakerPrint], prefix: String)
        -> (turns: [SpeakerTurn], prints: [SpeakerPrint]) {
        let turns = turns.map { SpeakerTurn(speakerID: prefix + $0.speakerID, start: $0.start, end: $0.end) }
        let prints = prints.map { print in
            var copy = print
            copy.speakerID = prefix + print.speakerID
            return copy
        }
        return (turns, prints)
    }

    /// Whether `turns` can attribute anything: at least one turn has a finite, positive length.
    public static func canAttribute(_ turns: [SpeakerTurn]) -> Bool { turns.contains(where: \.isValid) }

    /// Seconds in which `speakerID` speaks and nobody else does.
    public static func isolatedSeconds(speakerID: String, turns: [SpeakerTurn]) -> Double {
        var events: [(time: Double, own: Int, other: Int)] = []
        for turn in turns where turn.isValid {
            let own = turn.speakerID == speakerID
            events.append((turn.start, own ? 1 : 0, own ? 0 : 1))
            events.append((turn.end, own ? -1 : 0, own ? 0 : -1))
        }
        events.sort { $0.time < $1.time }
        var own = 0, other = 0, duration = 0.0
        var previous = events.first?.time ?? 0
        for event in events {
            if own > 0 && other == 0 { duration += max(0, event.time - previous) }
            own += event.own; other += event.other; previous = event.time
        }
        return duration
    }

    /// The transcript with a speaker on every passage. Without a valid turn it is returned unchanged.
    public static func assign(_ transcript: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        let union = unionTurns(turns)
        guard !union.isEmpty else { return transcript }
        return transcript.flatMap { segment -> [TranscriptSegment] in
            guard !segment.words.isEmpty else {
                var copy = segment
                copy.speakerID = speaker(start: segment.start, end: segment.end, union: union)
                return [copy]
            }
            let speakers = segment.words.map { speaker(start: $0.start, end: $0.end, union: union) }
            if Set(speakers).count == 1 {
                var copy = segment
                copy.speakerID = speakers[0]
                return [copy]
            }
            return split(segment, speakers: speakers)
        }
    }

    /// The pieces of a passage that several speakers share: a run of words per speaker, in order.
    private static func split(_ segment: TranscriptSegment, speakers: [String]) -> [TranscriptSegment] {
        var pieces: [TranscriptSegment] = []
        for (word, speaker) in zip(segment.words, speakers) {
            if let last = pieces.indices.last, pieces[last].speakerID == speaker {
                pieces[last].words.append(word)
                pieces[last].text += word.text
                pieces[last].end = max(pieces[last].end, word.end)
            } else {
                let id = pieces.isEmpty ? segment.id : derivedID(segment.id, piece: pieces.count)
                pieces.append(TranscriptSegment(id: id, text: word.text, start: word.start, end: word.end,
                                                speakerID: speaker, words: [word]))
            }
        }
        return pieces.map { piece in
            var copy = piece
            copy.text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
    }

    /// A speaker's overlapping turns joined into one, then every turn in time order.
    private static func unionTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        let valid = turns.filter(\.isValid)
        let bySpeaker = Dictionary(grouping: valid, by: \.speakerID)
        var union: [SpeakerTurn] = []
        for (_, intervals) in bySpeaker {
            var merged: [SpeakerTurn] = []
            for turn in intervals.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
                if let last = merged.indices.last, turn.start <= merged[last].end {
                    merged[last].end = max(merged[last].end, turn.end)
                } else {
                    merged.append(turn)
                }
            }
            union += merged
        }
        return union.sorted { ($0.start, $0.end, $0.speakerID) < ($1.start, $1.end, $1.speakerID) }
    }

    /// The speaker with the most overlap with `start..<end`, else the one with the nearest turn.
    private static func speaker(start: Double, end: Double, union: [SpeakerTurn]) -> String {
        var overlaps: [(speaker: String, seconds: Double)] = []
        for turn in union {
            let overlap = min(end, turn.end) - max(start, turn.start)
            guard overlap > 0 else { continue }
            if let index = overlaps.firstIndex(where: { $0.speaker == turn.speakerID }) {
                overlaps[index].seconds += overlap
            } else {
                overlaps.append((turn.speakerID, overlap))
            }
        }
        // The first of equal values wins, so ties go to the earlier turn (`max(by:)` would return the last).
        var best = overlaps.first
        for overlap in overlaps.dropFirst() where overlap.seconds > best!.seconds { best = overlap }
        if let best { return best.speaker }
        func gap(_ turn: SpeakerTurn) -> Double { max(turn.start - end, start - turn.end, 0) }
        var nearest = union[0]
        for turn in union.dropFirst() where gap(turn) < gap(nearest) { nearest = turn }
        return nearest.speakerID
    }

    /// A UUID made from `id` and the piece number, the same every time.
    static func derivedID(_ id: UUID, piece: Int) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data((id.uuidString + "/\(piece)").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
