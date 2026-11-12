import Foundation

/// A speaker's label as the transcript shows it: a name, an unnamed speaker's placeholder with its number ("Speaker 3",
/// or "Voce 3" as an Italian app wrote it), each as stored (D47), or nobody for passages without a speaker.
public enum SpeakerName: Hashable, Sendable {
    case named(String)
    case placeholder(Int, label: String)
    case unknown

    public var isNamed: Bool { if case .named = self { true } else { false } }
}

/// One word of a paragraph: its text as the paragraph shows it and where it starts in the audio.
public struct TurnWord: Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Index in the canonical input, independent of its reading position (including chips).
    public var sourceIndex: Int
    public var speakerID: String?
    public init(text: String, start: TimeInterval, end: TimeInterval? = nil,
                sourceIndex: Int = 0, speakerID: String? = nil) {
        self.text = text; self.start = start; self.end = end ?? start
        self.sourceIndex = sourceIndex; self.speakerID = speakerID
    }
}

/// An inline aside. Character ranges include its spoken label and parentheses; wordRange indexes actual atoms.
public struct TurnInterjection: Hashable, Sendable {
    public let speakerID: String?
    public let name: SpeakerName
    public let tint: SpeakerTint
    public let wordRange: Range<Int>
    public let textRange: Range<Int>
    public let nameRange: Range<Int>
    public let crosstalk: Bool
}

/// One viewer-defined reading paragraph. The host's speech and inline chips share one searchable, seekable text.
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
    public private(set) var unsettledFrom: Int?
    /// Rejoined words need not be chronological, so tentative words are tracked individually.
    public private(set) var unsettledWordIndices: Set<Int>
    public let continuation: Bool
    public let over: [SpeakerName]
    public let crosstalk: Bool
    public let interjections: [TurnInterjection]
    /// "Is this Luca?" above this paragraph: the speaker's first one, while it is a placeholder.
    public private(set) var suggestion: SpeakerSuggestion?
    /// Suggestions for speakers who speak in this row's inline chips instead of owning its header.
    public private(set) var inlineSuggestions: [SpeakerSuggestion]
    /// Host first, then the inline speakers in reading order; each card names its own actual speaker.
    public var allSuggestions: [SpeakerSuggestion] {
        var seen = Set<String>()
        return ((suggestion.map { [$0] } ?? []) + inlineSuggestions).filter { seen.insert($0.speakerID).inserted }
    }
    /// The passages the paragraph shows, in order, each with where it starts in the paragraph (for Edit passage).
    public let passages: [PassageRef]

    /// The speaker the header names (Name a speaker): nil for a passage without a speaker, and for the draft's one
    /// voice (`NoteTranscripts.draftOneVoice`), which the job names only once it saves the words under the run's id
    /// (D59), so its header is only a label.
    public var nameableSpeakerID: String? { speakerID == NoteTranscripts.draftOneVoice ? nil : speakerID }

    /// The character range of word `index` in `text`.
    public func range(ofWord index: Int) -> Range<Int> {
        offsets[index]..<(offsets[index] + words[index].text.count)
    }

    /// The word whose characters hold or precede `offset`.
    public func word(atOffset offset: Int) -> Int? {
        guard !offsets.isEmpty else { return nil }
        if let chip = interjections.first(where: { $0.textRange.contains(offset) }),
           offset < offsets[chip.wordRange.lowerBound] { return chip.wordRange.lowerBound }
        var low = 0, high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// A passage of the note as a paragraph shows it: its id and the start of its first word there.
public struct PassageRef: Hashable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public init(id: UUID, start: TimeInterval) { self.id = id; self.start = start }
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
        // Reading order keeps each turn together; playback order remains chronological.
        // Equal starts retain canonical source order rather than the chips' display positions.
        let order = starts.indices.sorted {
            if starts[$0] != starts[$1] { return starts[$0] < starts[$1] }
            return turns[turnOf[$0]].words[inTurn[$0]].sourceIndex < turns[turnOf[$1]].words[inTurn[$1]].sourceIndex
        }
        self.starts = order.map { starts[$0] }; self.turnOf = order.map { turnOf[$0] }
        self.inTurn = order.map { inTurn[$0] }; self.positions = positions
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
        for word in turns.flatMap(\.words).sorted(by: { $0.sourceIndex < $1.sourceIndex }) {
            if let id = word.speakerID, seen.insert(id).inserted { order.append(id) }
        }
        return order
    }
}

/// The pure mapping from a note's passages (sealed) or a job's draft words to `NoteTranscript` (Android
/// `NoteTranscripts`).
public enum NoteTranscripts {
    /// The name a speaker shows: its label as stored, a placeholder in whichever language it was written in (D47). A
    /// speaker without a label (none, blank, or its id) is "Speaker `ordinal + 1`" in the app's language.
    public static func name(label: String?, id: String, ordinal: Int) -> SpeakerName {
        if let label, let number = DefaultLabels.placeholderNumber(label) { return .placeholder(number, label: label) }
        guard let label, !DefaultLabels.isDefault(id: id, label: label) else { return unlabeled(ordinal + 1) }
        return .named(label)
    }

    private static func unlabeled(_ number: Int) -> SpeakerName {
        .placeholder(number, label: DefaultLabels.placeholder(number))
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
        return build(words, endsBoundedByAudio: !note.transcript.isEmpty && note.transcript.allSatisfy { $0.wordEndsBoundedByAudio == true }) { speaker, first in
            guard let speaker else { return Template(name: .unknown, tint: .stone) }
            let name = names[speaker] ?? unlabeled(1)
            var auto = false
            if case .auto(let voice, _) = speakers[speaker]?.match, case .named(let label) = name,
               let voiceName = voiceNames[voice] {
                auto = NameMatch.same(label, voiceName)
            }
            let suggestion = first && !name.isNamed && suggested.insert(speaker).inserted ? cards[speaker] : nil
            return Template(name: name, tint: tints[speaker] ?? .stone, auto: auto, suggestion: suggestion)
        }
    }

    /// The draft of a running or stopped job: each speaker's `labels` (placeholders numbered by first word without
    /// one), the "auto" badge for the `automatic` ones, the `suggestions` cards, each above the first paragraph of its
    /// speaker's latest turn, and `tentativeFromMs`: words that end after it may still change (nil for a stopped
    /// draft, whose words are all settled). Words without a speaker id (Apple Speech, or no speakers told apart) are
    /// one voice, "Speaker 1", as the job saves them (`NoteSpeaker.oneVoice`, D59), under `draftOneVoice`.
    public static func draft(_ words: [DraftWord], tentativeFromMs: Int64?, labels: [String: String] = [:],
                             automatic: Set<String> = [], suggestions: [DraftSuggestion] = []) -> NoteTranscript {
        let transcriptWords = words.map {
            TranscriptWord(speaker: $0.speaker.isEmpty ? draftOneVoice : $0.speaker, start: Double($0.startMs) / 1000,
                           end: Double($0.endMs) / 1000, text: $0.text, lowConfidenceSpeaker: $0.lowConfidenceSpeaker == true)
        }
        let order = orderOfAppearance(transcriptWords)
        var names: [String: SpeakerName] = [:]
        for (ordinal, id) in order.enumerated() { names[id] = name(label: labels[id], id: id, ordinal: ordinal) }
        let tints = SpeakerTint.assign(order) { names[$0]?.isNamed != true }
        let built = build(transcriptWords) { speaker, _ in
            guard let speaker else { return Template(name: .unknown, tint: .stone) }
            let name = names[speaker] ?? unlabeled(1)
            return Template(name: name, tint: tints[speaker] ?? .stone, auto: automatic.contains(speaker) && name.isNamed)
        }
        let cards = Dictionary(suggestions.map { ($0.speakerID, $0) }, uniquingKeysWith: { first, _ in first })
        var placedSpeakers = Set<String>()
        let placed = NoteTranscript(turns: built.turns.map { turn in
            // The latest raw speaker run can start inside a rejoined row or one of its chips. Anchor to the
            // actual word, not the host's row timestamp, while emitting each speaker's card only once.
            var host: SpeakerSuggestion?, inline: [SpeakerSuggestion] = []
            for word in turn.words {
                guard let id = word.speakerID, let card = cards[id], names[id]?.isNamed != true,
                      ms(word.start) == card.atMs, placedSpeakers.insert(id).inserted else { continue }
                let label = names[id]?.label ?? DefaultLabels.placeholder(1)
                let suggestion = SpeakerSuggestion(speakerID: id, label: label, voiceID: card.voiceID, voiceName: card.name,
                                                   score: card.score, segmentID: draftSegment, start: word.start)
                if id == turn.speakerID { host = suggestion } else { inline.append(suggestion) }
            }
            return turn.with(suggestion: host, inlineSuggestions: inline)
        })
        guard let tentativeFromMs else { return placed }
        let tentativeFrom = Double(tentativeFromMs) / 1000
        let turns = placed.turns.map { turn in
            turn.with(unsettledWordIndices: Set(turn.words.indices.filter { turn.words[$0].end > tentativeFrom }))
        }
        return NoteTranscript(turns: turns)
    }

    /// The speaker id a draft shows its words without a speaker under: the run's one voice has no id until the job
    /// saves the words, so it cannot be named in the draft (`NoteTurn.nameableSpeakerID`).
    public static let draftOneVoice = "draft_1"

    /// The `segmentID` of a draft's suggestion cards: a draft has no passages yet.
    public static let draftSegment = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func ms(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

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

    /// The exact viewer pipeline decides rows. Source indices, not contiguous slices, preserve playback and edits.
    private static func build(_ words: [TranscriptWord], endsBoundedByAudio: Bool = false, template: (String?, Bool) -> Template) -> NoteTranscript {
        let rows = TurnModel.rows(of: words.map {
            TurnModel.Word(speaker: $0.speaker, startMs: ($0.start * 1000).rounded(), endMs: ($0.end * 1000).rounded(), text: $0.text,
                           lowConfidenceSpeaker: $0.lowConfidenceSpeaker)
        }, endsBoundedByAudio: endsBoundedByAudio)
        var seen = Set<String?>()
        let speakerIDs = Set(words.compactMap(\.speaker))
        func sourceSpeaker(_ id: String?) -> String? {
            id == "Unknown speaker" && !speakerIDs.contains("Unknown speaker") ? nil : id
        }
        let turns = rows.map { row in
            let speaker = sourceSpeaker(row.speaker)
            let made = template(speaker, seen.insert(speaker).inserted)
            let indices = row.members.flatMap(\.wordIndices)
            var passages: [PassageRef] = [], seenPassages = Set<UUID>()
            for index in indices {
                let word = words[index]
                if let id = word.segmentID, seenPassages.insert(id).inserted {
                    passages.append(PassageRef(id: id, start: word.start))
                }
            }
            let over = row.over.map { template(sourceSpeaker($0), false).name }
            let inlineSuggestions = row.members.compactMap { member -> SpeakerSuggestion? in
                guard member.kind == .interjection else { return nil }
                let speaker = sourceSpeaker(member.speaker)
                return template(speaker, seen.insert(speaker).inserted).suggestion
            }
            return NoteTurn(id: "w\(indices.min()!)", speakerID: speaker, name: made.name, tint: made.tint,
                            start: row.startMs / 1000, auto: made.auto, source: words, row: row,
                            over: over, suggestion: made.suggestion, inlineSuggestions: inlineSuggestions, passages: passages, template: {
                let value = template(sourceSpeaker($0), false)
                return (value.name, value.tint)
            })
        }
        return NoteTranscript(turns: turns)
    }
}

extension SpeakerName {
    /// Stored labels stay unchanged; a speaker without one uses the app's localized fallback everywhere.
    public var label: String { label(language: DefaultLabels.appLanguage) }

    public func label(language: String) -> String {
        switch self {
        case .named(let label), .placeholder(_, let label): label
        case .unknown: DefaultLabels.unknown(language: language)
        }
    }
}

extension NoteTurn {
    init(id: String, speakerID: String?, name: SpeakerName, tint: SpeakerTint, start: TimeInterval, auto: Bool,
         source: [TranscriptWord], row: TurnModel.Row, over: [SpeakerName], suggestion: SpeakerSuggestion?,
         inlineSuggestions: [SpeakerSuggestion], passages: [PassageRef], template: (String?) -> (SpeakerName, SpeakerTint)) {
        var text = "", offsets: [Int] = [], words: [TurnWord] = [], chips: [TurnInterjection] = []
        for member in row.members {
            guard !member.wordIndices.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            let from = text.count, wordFrom = words.count
            let (chipName, chipTint) = template(member.speaker)
            let chip = member.kind == .interjection
            if chip { text += "(\(chipName.label): " }
            let nameRange = (from + 1)..<(from + 1 + chipName.label.count)
            let proseStart = text.count
            var cursor = member.text.startIndex
            for index in member.wordIndices {
                let word = source[index]
                // The viewer chooses spaces between atoms (including standalone punctuation).
                // Locate each original atom in that projection; its text and source time stay intact.
                let span = member.text.range(of: word.text, options: .literal, range: cursor..<member.text.endIndex)
                let offset = span.map { member.text.distance(from: member.text.startIndex, to: $0.lowerBound) }
                    ?? member.text.distance(from: member.text.startIndex, to: cursor)
                offsets.append(proseStart + offset)
                if let span { cursor = span.upperBound }
                words.append(TurnWord(text: word.text, start: word.start, end: word.end,
                                      sourceIndex: index, speakerID: word.speaker))
            }
            text += member.text
            if chip {
                text += ")"
                chips.append(TurnInterjection(speakerID: member.speaker, name: chipName, tint: chipTint,
                                              wordRange: wordFrom..<words.count, textRange: from..<text.count,
                                              nameRange: nameRange, crosstalk: member.crosstalk))
            }
        }
        self.id = id; self.speakerID = speakerID; self.name = name; self.tint = tint; self.start = start
        self.auto = auto; self.words = words; self.text = text; self.offsets = offsets
        self.unsettledFrom = nil; self.unsettledWordIndices = []
        self.continuation = row.continuation; self.over = over; self.crosstalk = row.crosstalk
        self.interjections = chips; self.suggestion = suggestion; self.inlineSuggestions = inlineSuggestions; self.passages = passages
    }

    func with(unsettledWordIndices: Set<Int>) -> NoteTurn {
        var copy = self
        copy.unsettledWordIndices = unsettledWordIndices
        copy.unsettledFrom = unsettledWordIndices.min()
        return copy
    }

    func with(suggestion: SpeakerSuggestion?, inlineSuggestions: [SpeakerSuggestion]) -> NoteTurn {
        var copy = self
        copy.suggestion = suggestion
        copy.inlineSuggestions = inlineSuggestions
        return copy
    }
}
