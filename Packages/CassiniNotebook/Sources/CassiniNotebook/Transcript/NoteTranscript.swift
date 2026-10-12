import Foundation

/// A speaker's label as the transcript shows it: a name verbatim, a placeholder number the app shows as "Speaker 3",
/// or nobody for passages without a speaker. The stored label is not changed.
public enum SpeakerName: Hashable, Sendable {
    case named(String)
    case placeholder(Int)
    case unknown

    public var isNamed: Bool { if case .named = self { true } else { false } }
}

/// One word of a paragraph: its text as the paragraph shows it and where it starts in the audio.
public struct TurnWord: Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public init(text: String, start: TimeInterval) { self.text = text; self.start = start }
}

/// One paragraph of the transcript (Android `TurnUi`): the words of one speaker in a row, cut into paragraphs of at
/// most `NoteTranscripts.maxTurnWords` words.
///
/// `id` is `w<index>` of its first word in the whole transcript, so it stays the same while later words change.
/// `text` joins the words; `offsets` gives each word's first character in it, so search ranges and the active word
/// index into the same string. In the draft, the words from `unsettledFrom` on may still change.
public struct NoteTurn: Identifiable, Hashable, Sendable {
    public let id: String
    public let speakerID: String?
    public let name: SpeakerName
    public let tint: SpeakerTint
    public let start: TimeInterval
    /// The speaker carries a saved voice's name that Cassini gave it ("auto" badge).
    public let auto: Bool
    public let words: [TurnWord]
    public let text: String
    public let offsets: [Int]
    public let unsettledFrom: Int?
    /// "Is this Luca?" above this paragraph: the speaker's first one, while it is a placeholder.
    public let suggestion: SpeakerSuggestion?
    /// The passages the paragraph shows, in order (for Edit passage).
    public let segmentIDs: [UUID]

    /// The character range of word `index` in `text`.
    public func range(ofWord index: Int) -> Range<Int> {
        offsets[index]..<(offsets[index] + words[index].text.count)
    }

    /// The word whose characters hold or precede `offset`.
    public func word(atOffset offset: Int) -> Int? {
        guard !offsets.isEmpty else { return nil }
        var low = 0, high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Word `index` of the paragraph `turnID` (the active word, a word tap).
public struct WordRef: Hashable, Sendable {
    public var turnID: String
    public var index: Int
    public init(turnID: String, index: Int) { self.turnID = turnID; self.index = index }
}

/// The transcript the Note screen shows (Android `NoteTranscript`): its paragraphs and an index from audio time to
/// word for the active word. Built once per transcript; the playback position only searches the index.
public struct NoteTranscript: Hashable, Sendable {
    public let turns: [NoteTurn]
    private let starts: [TimeInterval]
    private let turnOf: [Int]
    private let inTurn: [Int]
    private let positions: [String: Int]

    public static let empty = NoteTranscript(turns: [])

    init(turns: [NoteTurn]) {
        self.turns = turns
        var starts: [TimeInterval] = [], turnOf: [Int] = [], inTurn: [Int] = []
        var positions: [String: Int] = [:]
        for (position, turn) in turns.enumerated() {
            positions[turn.id] = position
            for (index, word) in turn.words.enumerated() {
                starts.append(word.start); turnOf.append(position); inTurn.append(index)
            }
        }
        self.starts = starts; self.turnOf = turnOf; self.inTurn = inTurn; self.positions = positions
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// The word playing at `position`: the last word that started at or before it; nil before the first. Between two
    /// words the earlier one stays active; of words with the same start, the last plays.
    public func activeWord(at position: TimeInterval) -> WordRef? {
        // The first index whose start is after the position, less one.
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= position { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard index >= 0 else { return nil }
        return WordRef(turnID: turns[turnOf[index]].id, index: inTurn[index])
    }

    public func turn(_ id: String) -> NoteTurn? { positions[id].map { turns[$0] } }

    /// Where the paragraph `id` sits in `turns`.
    public func position(of id: String) -> Int? { positions[id] }

    /// Where paragraph `turnID` starts in the audio.
    public func turnStart(_ turnID: String) -> TimeInterval? { turn(turnID)?.start }

    /// Where `word` starts in the audio.
    public func wordStart(_ word: WordRef) -> TimeInterval? {
        guard let turn = turn(word.turnID), turn.words.indices.contains(word.index) else { return nil }
        return turn.words[word.index].start
    }

    /// The speakers in order of their first paragraph.
    public var speakers: [String] {
        var seen = Set<String>(), order: [String] = []
        for turn in turns { if let id = turn.speakerID, seen.insert(id).inserted { order.append(id) } }
        return order
    }
}

/// The pure mapping from a note's passages (sealed) or a job's draft words to `NoteTranscript` (Android
/// `NoteTranscripts`).
public enum NoteTranscripts {
    /// A turn is cut into paragraphs of at most this many words, so one long speaker does not make one huge item. A
    /// paragraph also ends at a sentence end after `softTurnWords` words.
    public static let maxTurnWords = 200
    public static let softTurnWords = 120

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    /// The name a speaker shows: the label, or "Speaker N" from its placeholder number (`ordinal + 1` without one).
    public static func name(label: String?, id: String, ordinal: Int) -> SpeakerName {
        guard let label, !DefaultLabels.isDefault(id: id, label: label) else {
            return .placeholder(label.flatMap(DefaultLabels.placeholderNumber) ?? ordinal + 1)
        }
        return .named(label)
    }

    /// The shown transcript of `note`, with its speakers, the saved `voices` (for the "auto" badge) and the
    /// `suggestions` cards (`SpeakerSuggestions.of`), each at its speaker's first paragraph.
    ///
    /// "auto" shows when the speaker's match is automatic and its label is the voice's name.
    public static func sealed(_ note: Note, voices: [SavedVoice] = [], suggestions: [SpeakerSuggestion] = []) -> NoteTranscript {
        let words = note.transcriptWords
        let order = orderOfAppearance(words)
        let speakers = Dictionary((note.speakers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let labels = Dictionary(note.transcript.compactMap { s in s.speakerID.flatMap { id in s.speaker.map { (id, $0) } } },
                                uniquingKeysWith: { first, _ in first })
        var names: [String: SpeakerName] = [:]
        for (ordinal, id) in order.enumerated() {
            names[id] = name(label: speakers[id]?.name ?? labels[id], id: id, ordinal: ordinal)
        }
        let tints = SpeakerTint.assign(order) { names[$0]?.isNamed != true }
        let voiceNames = Dictionary(voices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let cards = Dictionary(suggestions.map { ($0.speakerID, $0) }, uniquingKeysWith: { first, _ in first })
        var suggested = Set<String>()
        return build(words) { speaker, first in
            guard let speaker else { return Template(name: .unknown, tint: .amber) }
            let name = names[speaker] ?? .placeholder(1)
            var auto = false
            if case .auto(let voice, _) = speakers[speaker]?.match, case .named(let label) = name,
               let voiceName = voiceNames[voice] {
                auto = NameMatch.same(label, voiceName)
            }
            let suggestion = first && !name.isNamed && suggested.insert(speaker).inserted ? cards[speaker] : nil
            return Template(name: name, tint: tints[speaker] ?? .amber, auto: auto, suggestion: suggestion)
        }
    }

    /// The draft of a running or stopped job: placeholders numbered by first word, and `tentativeFromMs`: words that
    /// end after it may still change (nil for a stopped draft, whose words are all settled).
    public static func draft(_ words: [DraftWord], tentativeFromMs: Int64?) -> NoteTranscript {
        let transcriptWords = words.map {
            TranscriptWord(speaker: $0.speaker, start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000, text: $0.text)
        }
        let order = orderOfAppearance(transcriptWords)
        let numbers = Dictionary(order.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        let built = build(transcriptWords) { speaker, _ in
            Template(name: .placeholder(speaker.flatMap { numbers[$0] } ?? 1), tint: .amber)
        }
        guard let tentativeFromMs else { return built }
        let tentativeFrom = Double(tentativeFromMs) / 1000
        var position = 0
        let turns = built.turns.map { turn -> NoteTurn in
            defer { position += turn.words.count }
            let unsettled = (0..<turn.words.count).first { transcriptWords[position + $0].end > tentativeFrom }
            return turn.with(unsettledFrom: unsettled)
        }
        return NoteTranscript(turns: turns)
    }

    // MARK: Building

    private struct Template {
        var name: SpeakerName
        var tint: SpeakerTint
        var auto = false
        var suggestion: SpeakerSuggestion?
    }

    private static func orderOfAppearance(_ words: [TranscriptWord]) -> [String] {
        var seen = Set<String>(), order: [String] = []
        for word in words { if let id = word.speaker, seen.insert(id).inserted { order.append(id) } }
        return order
    }

    /// The paragraphs of `words`, each from `template` (speaker, whether it is the speaker's first paragraph).
    private static func build(_ words: [TranscriptWord], template: (String?, Bool) -> Template) -> NoteTranscript {
        var turns: [NoteTurn] = []
        var seen = Set<String?>()
        var from = 0
        while from < words.count {
            let to = paragraphEnd(words, from: from)
            let run = words[from..<to]
            let made = template(run.first!.speaker, seen.insert(run.first!.speaker).inserted)
            var segmentIDs: [UUID] = []
            for word in run { if let id = word.segmentID, segmentIDs.last != id { segmentIDs.append(id) } }
            turns.append(NoteTurn(id: "w\(from)", speakerID: run.first!.speaker, name: made.name, tint: made.tint,
                                  start: run.first!.start, auto: made.auto, words: Array(run),
                                  suggestion: made.suggestion, segmentIDs: segmentIDs))
            from = to
        }
        return NoteTranscript(turns: turns)
    }

    /// The end (exclusive) of the paragraph from `from`: the speaker's run, cut as `maxTurnWords` says.
    private static func paragraphEnd(_ words: [TranscriptWord], from: Int) -> Int {
        var to = from + 1
        while to < words.count, words[to].speaker == words[from].speaker, !paragraphFull(words, from: from, to: to) { to += 1 }
        return to
    }

    private static func paragraphFull(_ words: [TranscriptWord], from: Int, to: Int) -> Bool {
        let length = to - from
        let sentenceEnd = words[to - 1].text.last.map(sentenceEnds.contains) ?? false
        return length >= maxTurnWords || (length >= softTurnWords && sentenceEnd)
    }
}

extension NoteTurn {
    init(id: String, speakerID: String?, name: SpeakerName, tint: SpeakerTint, start: TimeInterval, auto: Bool,
         words: [TranscriptWord], unsettledFrom: Int? = nil, suggestion: SpeakerSuggestion?, segmentIDs: [UUID]) {
        var text = "", offsets: [Int] = [], length = 0
        for (index, word) in words.enumerated() {
            if index > 0, word.spaceBefore { text += " "; length += 1 }
            offsets.append(length)
            text += word.text; length += word.text.count
        }
        self.id = id; self.speakerID = speakerID; self.name = name; self.tint = tint; self.start = start
        self.auto = auto; self.words = words.map { TurnWord(text: $0.text, start: $0.start) }
        self.text = text; self.offsets = offsets; self.unsettledFrom = unsettledFrom
        self.suggestion = suggestion; self.segmentIDs = segmentIDs
    }

    func with(unsettledFrom: Int?) -> NoteTurn {
        NoteTurn(id: id, speakerID: speakerID, name: name, tint: tint, start: start, auto: auto, words: words,
                 text: text, offsets: offsets, unsettledFrom: unsettledFrom, suggestion: suggestion, segmentIDs: segmentIDs)
    }
}
