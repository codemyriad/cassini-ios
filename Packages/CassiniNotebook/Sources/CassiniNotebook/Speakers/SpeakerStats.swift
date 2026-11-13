import CassiniCore
import Foundation

/// The "Play a sample" range of a speaker, in seconds of the note's audio.
public struct SampleWindow: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
}

/// What a transcript says about one speaker. `ordinal` is the order of first appearance (from 0), `speakingTime` the
/// summed length of the speaker's turns, `firstStart` the start of the first turn and `sample` the "Play a sample"
/// window, or nil when no turn lasts `SpeakerStats.sampleMinimum`.
public struct SpeakerStat: Hashable, Sendable {
    public var speakerID: String
    public var ordinal: Int
    public var speakingTime: Double
    public var turnCount: Int
    public var wordCount: Int
    public var firstStart: Double
    public var sample: SampleWindow?
}

/// Per-speaker numbers for the Speakers list, the Name a speaker sheet and the Merge sheet.
///
/// A turn is a run of consecutive passages with the same speaker; it starts at its first passage's start and ends at
/// its last passage's end. Passages without a speaker belong to nobody but still end a turn.
public enum SpeakerStats {
    /// A sample plays at most this much of its turn.
    public static let sampleMaximum: Double = 10
    /// A turn shorter than this is no sample.
    public static let sampleMinimum: Double = 1

    private struct Turn {
        var speakerID: String
        var start: Double
        var end: Double
        var words: Int
        var length: Double { max(0, end - start) }
    }

    /// The stats of every speaker in `transcript`, in order of first appearance. The sample is the longest turn (ties:
    /// the earliest start, then the first in order), cut to `sampleMaximum`.
    public static func of(_ transcript: [TranscriptSegment]) -> [SpeakerStat] {
        var turns: [Turn?] = []
        for segment in transcript {
            let words = segment.words.isEmpty ? segment.text.split(whereSeparator: \.isWhitespace).count : segment.words.count
            guard let speaker = segment.speakerID else { turns.append(nil); continue }
            if let last = turns.last, var turn = last, Data(turn.speakerID.utf8) == Data(speaker.utf8) {
                turn.end = segment.end
                turn.words += words
                turns[turns.count - 1] = turn
            } else {
                turns.append(Turn(speakerID: speaker, start: segment.start, end: segment.end, words: words))
            }
        }
        let spoken = turns.compactMap { $0 }
        var order: [String] = []
        for turn in spoken where !order.contains(where: { Data($0.utf8) == Data(turn.speakerID.utf8) }) { order.append(turn.speakerID) }
        return order.enumerated().map { ordinal, id in
            let own = spoken.filter { Data($0.speakerID.utf8) == Data(id.utf8) }
            var longest = own[0]
            for turn in own.dropFirst() where turn.length > longest.length || (turn.length == longest.length && turn.start < longest.start) {
                longest = turn
            }
            let sample = longest.length < sampleMinimum
                ? nil : SampleWindow(start: longest.start, end: min(longest.end, longest.start + sampleMaximum))
            return SpeakerStat(speakerID: id, ordinal: ordinal, speakingTime: own.reduce(0) { $0 + $1.length },
                               turnCount: own.count, wordCount: own.reduce(0) { $0 + $1.words },
                               firstStart: own[0].start, sample: sample)
        }
    }

    /// The stats of every speaker of the format's `words` (canonical order, milliseconds), each word its own passage,
    /// as Android's `SpeakerStats.of(words)`.
    public static func of(words: [Word]) -> [SpeakerStat] {
        of(words.map { word in
            let start = Double(word.startMs) / 1000, end = Double(word.endMs) / 1000
            return TranscriptSegment(text: word.text, start: start, end: end, speakerID: word.speaker,
                                     words: [TimedWord(text: word.text, start: start, end: end)])
        })
    }

    /// The stats of a draft: `merges` (`names.json`) applied with `SpeakerMerges.apply` first. Throws on a merge
    /// cycle, as `SpeakerMerges` does.
    public static func of(draft transcript: Transcript, merges: [String: String]) throws -> [SpeakerStat] {
        of(words: try SpeakerMerges.apply(transcript, aliases: merges).words)
    }

    /// The stats of one speaker, or nil when the speaker says nothing in `transcript`.
    public static func of(_ speakerID: String, in transcript: [TranscriptSegment]) -> SpeakerStat? {
        of(transcript).first { Data($0.speakerID.utf8) == Data(speakerID.utf8) }
    }
}

extension Note {
    /// Seconds `speakerID` speaks in the shown transcript.
    public func speakingTime(for speakerID: String) -> Double {
        SpeakerStats.of(speakerID, in: transcript)?.speakingTime ?? 0
    }
}
