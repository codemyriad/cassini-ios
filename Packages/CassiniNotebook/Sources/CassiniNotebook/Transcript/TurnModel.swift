import Foundation

/// The words-only viewer projection pinned by D84 to gocassini 1111155cb0017b47c072a8662c54f28ad7c44223.
/// Input order is canonical: paragraph grouping precedes timing repair and chronological turn reconstruction.
public enum TurnModel {
    public struct Word: Hashable, Sendable {
        public var speaker: String?
        public var startMs: Double
        public var endMs: Double
        public var text: String
        public var lowConfidenceSpeaker: Bool

        public init(speaker: String?, startMs: Double, endMs: Double, text: String,
                    lowConfidenceSpeaker: Bool = false) {
            self.speaker = speaker
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.lowConfidenceSpeaker = lowConfidenceSpeaker
        }
    }

    public struct Member: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable { case words, interjection }
        public var kind: Kind
        public var speaker: String?
        public var crosstalk: Bool
        public var wordIndices: [Int]
        public var text: String

        public init(kind: Kind, speaker: String? = nil, crosstalk: Bool = false,
                    wordIndices: [Int], text: String) {
            self.kind = kind
            self.speaker = speaker
            self.crosstalk = crosstalk
            self.wordIndices = wordIndices
            self.text = text
        }
    }

    public struct Row: Hashable, Sendable {
        public var speaker: String?
        public var continuation: Bool
        public var startMs: Double
        public var endMs: Double
        public var over: [String]
        public var crosstalk: Bool
        public var members: [Member]

        public init(speaker: String?, continuation: Bool, startMs: Double, endMs: Double,
                    over: [String], crosstalk: Bool, members: [Member]) {
            self.speaker = speaker
            self.continuation = continuation
            self.startMs = startMs
            self.endMs = endMs
            self.over = over
            self.crosstalk = crosstalk
            self.members = members
        }
    }

    /// Each input item is one canonical word. Returned indices always name the original input, never a sorted copy.
    /// Audio-bounded files bypass legacy punctuation-tail repair; their measured ends are already authoritative.
    public static func rows(of words: [Word], endsBoundedByAudio: Bool = false) -> [Row] {
        let raw = readableBlocks(words)
        let repaired = endsBoundedByAudio ? raw : repairTiming(raw)
        let ordered = repaired.enumerated().sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }.map(\.element)
        let runs = turnRuns(ordered)
        let nested = nestedRuns(runs)
        let over = competingSpeakers(runs, nested: nested)
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        var rows: [Row] = []

        // Keep a turn's paragraphs together, even when another turn starts before its last paragraph.
        for (runIndex, run) in runs.enumerated() where nested[runIndex] == nil {
            let children = nested.keys.filter { nested[$0]?.host == runIndex }.sorted {
                runs[$0].startMs == runs[$1].startMs ? $0 < $1 : runs[$0].startMs < runs[$1].startMs
            }
            var atSeam: [Int: [Int]] = [:]
            for child in children {
                if let seam = nested[child] { atSeam[seam.beforeID, default: []].append(child) }
            }
            var paragraphs: [[LayoutMember]] = []
            var current: [LayoutMember] = []
            var previous: Block?
            for block in run.blocks {
                if let previous, current.last?.kind == .words,
                   let before = position[previous.id], let after = position[block.id], after == before + 1 {
                    paragraphs.append(current)
                    current = []
                }
                current.append(LayoutMember(kind: .words, blocks: [block]))
                for child in atSeam[block.id] ?? [] {
                    current.append(LayoutMember(kind: .interjection, blocks: runs[child].blocks))
                }
                previous = block
            }
            if !current.isEmpty { paragraphs.append(current) }
            for (paragraphIndex, paragraph) in paragraphs.enumerated() {
                let blocks = paragraph.flatMap(\.blocks)
                let ownWords = paragraph.filter { $0.kind == .words }.flatMap(\.blocks).flatMap(\.words)
                rows.append(Row(speaker: run.key, continuation: false,
                    startMs: blocks.map(\.startMs).min() ?? run.startMs,
                    endMs: blocks.map(\.endMs).max() ?? run.endMs,
                    over: paragraphIndex == 0 ? over[runIndex] ?? [] : [],
                    crosstalk: likelyCrosstalk(ownWords), members: paragraph.map { member in
                        Member(kind: member.kind,
                            speaker: member.kind == .interjection ? (member.blocks.first?.speaker ?? "Unknown speaker") : nil,
                            crosstalk: member.kind == .interjection && likelyCrosstalk(member.blocks.flatMap(\.words)),
                            wordIndices: member.blocks.flatMap(\.words).map(\.index),
                            text: member.blocks.map(\.text).joined(separator: " "))
                    }))
            }
        }
        for index in rows.indices.dropFirst() {
            let previous = rows[index - 1]
            if let speaker = rows[index].speaker, !speaker.isEmpty, speaker == previous.speaker,
               rows[index].startMs - previous.endMs <= 60_000 {
                rows[index].continuation = true
            }
        }
        return rows
    }
}

extension TurnModel {
    struct TimedWord {
        var index: Int
        var word: Word
    }

    struct Block {
        var id: Int
        var speaker: String?
        var startMs: Double
        var endMs: Double
        var text: String
        var words: [TimedWord]

        var spans: [Interval] {
            let timed = words.compactMap { item -> Interval? in
                let word = item.word
                guard word.startMs.isFinite, word.endMs.isFinite, word.endMs > word.startMs else { return nil }
                return Interval(start: word.startMs, end: word.endMs)
            }
            // The viewer falls back to the block envelope when no measured positive span exists.
            return timed.isEmpty ? [Interval(start: startMs, end: endMs)] : mergeIntervals(timed)
        }
    }

    struct LayoutMember {
        var kind: Member.Kind
        var blocks: [Block]
    }

    static func likelyCrosstalk(_ words: [TimedWord]) -> Bool {
        !words.isEmpty && words.allSatisfy { $0.word.lowConfidenceSpeaker }
    }
}
