import Foundation

/// A speaker's label as the transcript shows it: a name, an unnamed speaker's placeholder with its number ("Speaker 3",
/// or "Voce 3" as an Italian app wrote it), each as stored (D47), or nobody for passages without a speaker.
public enum SpeakerName: Hashable, Sendable {
    case named(String)
    case placeholder(Int, label: String)
    case unknown

    public var isNamed: Bool { if case .named = self { true } else { false } }
}

/// A speaker shown in the meeting header, in canonical word order rather than paragraph display order.
public struct TranscriptSpeaker: Identifiable, Hashable, Sendable {
    public let id: String
    public var byteID: Data { Data(id.utf8) }
    public let name: SpeakerName
    public let tint: SpeakerTint
    public let auto: Bool

    public init(id: String, name: SpeakerName, tint: SpeakerTint, auto: Bool) {
        self.id = id; self.name = name; self.tint = tint; self.auto = auto
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byteID == rhs.byteID && lhs.name == rhs.name && lhs.tint == rhs.tint && lhs.auto == rhs.auto
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(byteID); hasher.combine(name); hasher.combine(tint); hasher.combine(auto)
    }

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
    public let auto: Bool

    public init(speakerID: String?, name: SpeakerName, tint: SpeakerTint, wordRange: Range<Int>,
                textRange: Range<Int>, nameRange: Range<Int>, crosstalk: Bool, auto: Bool = false) {
        self.speakerID = speakerID; self.name = name; self.tint = tint
        self.wordRange = wordRange; self.textRange = textRange; self.nameRange = nameRange
        self.crosstalk = crosstalk; self.auto = auto
    }
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
        var seen = Set<Data>()
        return ((suggestion.map { [$0] } ?? []) + inlineSuggestions).filter { seen.insert($0.byteSpeakerID).inserted }
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
    /// IDs in first canonical word order, cached while constructing the playback index.
    public let speakers: [String]
    /// Header metadata includes speakers who only appear in inline interjections.
    public let headerSpeakers: [TranscriptSpeaker]
    public let speakerTints: [String: SpeakerTint]
    private let speakerTintsByID: [Data: SpeakerTint]

    public func speakerTint(for id: String) -> SpeakerTint? { speakerTintsByID[Data(id.utf8)] }
    private let starts: [TimeInterval]
    private let turnOf: [Int]
    private let inTurn: [Int]
    private let positions: [String: Int]

    public static let empty = NoteTranscript(turns: [])

    init(turns: [NoteTurn]) {
        self.turns = turns
        var starts: [TimeInterval] = [], turnOf: [Int] = [], inTurn: [Int] = []
        var positions: [String: Int] = [:]
        var speakerTints: [String: SpeakerTint] = [:]
        var exactTints: [Data: SpeakerTint] = [:]
        var firstWords: [Data: (id: String, source: Int, encounter: Int)] = [:]
        var metadata: [Data: TranscriptSpeaker] = [:]
        func remember(_ id: String?, name: SpeakerName, tint: SpeakerTint, auto: Bool) {
            guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name != .unknown else { return }
            let key = Data(id.utf8)
            guard metadata[key] == nil else { return }
            metadata[key] = TranscriptSpeaker(id: id, name: name, tint: tint, auto: auto)
        }
        for (position, turn) in turns.enumerated() {
            positions[turn.id] = position
            remember(turn.speakerID, name: turn.name, tint: turn.tint, auto: turn.auto)
            for chip in turn.interjections {
                remember(chip.speakerID, name: chip.name, tint: chip.tint, auto: chip.auto)
            }
            if let id = turn.speakerID { speakerTints[id] = turn.tint; exactTints[Data(id.utf8)] = turn.tint }
            for chip in turn.interjections { if let id = chip.speakerID { speakerTints[id] = chip.tint; exactTints[Data(id.utf8)] = chip.tint } }
            for (index, word) in turn.words.enumerated() {
                if let id = word.speakerID {
                    let key = Data(id.utf8)
                    if firstWords[key].map({ word.sourceIndex < $0.source }) ?? true {
                        firstWords[key] = (id, word.sourceIndex, starts.count)
                    }
                }
                starts.append(word.start); turnOf.append(position); inTurn.append(index)
            }
        }
        let speakerOrder = firstWords.keys.sorted {
            let lhs = firstWords[$0]!, rhs = firstWords[$1]!
            return lhs.source == rhs.source ? lhs.encounter < rhs.encounter : lhs.source < rhs.source
        }
        self.speakers = speakerOrder.map { firstWords[$0]!.id }
        self.headerSpeakers = speakerOrder.compactMap { metadata[$0] }
        self.speakerTints = speakerTints
        self.speakerTintsByID = exactTints
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
        sealed(note, voices: voices, suggestions: suggestions, colourOrder: SpeakerColourOrder.words)
    }

    static func sealed(_ note: Note, voices: [SavedVoice] = [], suggestions: [SpeakerSuggestion] = [],
                       colourOrder: ([TranscriptWord]) -> [String]) -> NoteTranscript {
        let words = note.transcriptWords
        let order = orderOfAppearance(words)
        let speakers = Dictionary((note.speakers ?? []).map { ($0.byteID, $0) }, uniquingKeysWith: { first, _ in first })
        let labels = Dictionary(note.transcript.compactMap { s in s.speakerID.flatMap { id in s.speaker.map { (Data(id.utf8), $0) } } },
                                uniquingKeysWith: { first, _ in first })
        var names: [Data: SpeakerName] = [:]
        for (ordinal, id) in order.enumerated() {
            if let speaker = speakers[Data(id.utf8)], speaker.provenance != .unnamed {
                names[Data(id.utf8)] = .named(speaker.name)
            } else {
                names[Data(id.utf8)] = name(label: speakers[Data(id.utf8)]?.name ?? labels[Data(id.utf8)], id: id, ordinal: ordinal)
            }
        }
        var paletteSpeakers = order.map { id in
            speakers[Data(id.utf8)] ?? NoteSpeaker(id: id, name: labels[Data(id.utf8)] ?? id)
        }
        if paletteSpeakers.contains(where: { $0.colourIndex == nil }) {
            paletteSpeakers = Note.assignColourIndices(paletteSpeakers, order: colourOrder(words))
        }
        let tints = SpeakerTint.assignByID(order, speakers: paletteSpeakers)
        let voiceNames = Dictionary(voices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let cards = Dictionary(suggestions.map { (Data($0.speakerID.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        var suggested = Set<Data>()
        return build(words, endsBoundedByAudio: !note.transcript.isEmpty && note.transcript.allSatisfy { $0.wordEndsBoundedByAudio == true }) { speaker, first in
            guard let speaker else { return Template(name: .unknown, tint: .stone) }
            let name = names[Data(speaker.utf8)] ?? unlabeled(1)
            var auto = false
            if case .auto(let voice, _) = speakers[Data(speaker.utf8)]?.match, case .named(let label) = name,
               let voiceName = voiceNames[voice] {
                auto = NameMatch.same(label, voiceName)
            }
            let suggestion = first && !name.isNamed && suggested.insert(Data(speaker.utf8)).inserted ? cards[Data(speaker.utf8)] : nil
            return Template(name: name, tint: tints[Data(speaker.utf8)] ?? .stone, auto: auto, suggestion: suggestion)
        }
    }

    /// The draft of a running or stopped job: each speaker's `labels` (placeholders numbered by first word without
    /// one), the "auto" badge for the `automatic` ones, the `suggestions` cards, each above the first paragraph of its
    /// speaker's latest turn, and `tentativeFromMs`: words that end after it may still change (nil for a stopped
    /// draft, whose words are all settled). Words without a speaker id (Apple Speech, or no speakers told apart) are
    /// one voice, "Speaker 1", as the job saves them (`NoteSpeaker.oneVoice`, D59), under `draftOneVoice`.
    public static func draft(_ words: [DraftWord], tentativeFromMs: Int64?, labels: [String: String] = [:],
                             automatic: Set<String> = [], suggestions: [DraftSuggestion] = [], colourIndices: [String: Int] = [:],
                             provenance: [String: NoteSpeaker.Provenance] = [:], labelsByID: [Data: String] = [:],
                             colourIndicesByID: [Data: Int] = [:], provenanceByID: [Data: NoteSpeaker.Provenance] = [:],
                             automaticByID: Set<Data> = []) -> NoteTranscript {
        draft(words, tentativeFromMs: tentativeFromMs, labels: labels, automatic: automatic, suggestions: suggestions,
              colourIndices: colourIndices, provenance: provenance, labelsByID: labelsByID,
              colourIndicesByID: colourIndicesByID, provenanceByID: provenanceByID, automaticByID: automaticByID,
              colourOrder: SpeakerColourOrder.words)
    }

    static func draft(_ words: [DraftWord], tentativeFromMs: Int64?, labels: [String: String] = [:],
                      automatic: Set<String> = [], suggestions: [DraftSuggestion] = [], colourIndices: [String: Int] = [:],
                      provenance: [String: NoteSpeaker.Provenance] = [:], labelsByID: [Data: String] = [:],
                      colourIndicesByID: [Data: Int] = [:], provenanceByID: [Data: NoteSpeaker.Provenance] = [:],
                      automaticByID: Set<Data> = [], colourOrder: ([TranscriptWord]) -> [String]) -> NoteTranscript {
        let transcriptWords = words.map {
            TranscriptWord(speaker: $0.speaker.isEmpty ? draftOneVoice : $0.speaker, start: Double($0.startMs) / 1000,
                           end: Double($0.endMs) / 1000, text: $0.text, lowConfidenceSpeaker: $0.lowConfidenceSpeaker == true)
        }
        // Legacy dictionaries retain their stored key bytes; exact overrides can represent canonical collisions.
        let labels = Dictionary(uniqueKeysWithValues: labels.map { (Data($0.key.utf8), $0.value) })
            .merging(labelsByID) { _, exact in exact }
        let provenance = Dictionary(uniqueKeysWithValues: provenance.map { (Data($0.key.utf8), $0.value) })
            .merging(provenanceByID) { _, exact in exact }
        let automatic = Set(automatic.map { Data($0.utf8) }).union(automaticByID)
        let order = orderOfAppearance(transcriptWords)
        var names: [Data: SpeakerName] = [:]
        for (ordinal, id) in order.enumerated() {
            let key = Data(id.utf8)
            names[key] = provenance[key].map { $0 == .unnamed ? unlabeled(ordinal + 1) : .named(labels[key] ?? id) }
                ?? name(label: labels[key], id: id, ordinal: ordinal)
        }
        var indices = Dictionary(uniqueKeysWithValues: colourIndices.map { (Data($0.key.utf8), $0.value) })
            .merging(colourIndicesByID) { _, exact in exact }
        if order.contains(where: { indices[Data($0.utf8)] == nil }) {
            var allocator = SpeakerColourAllocator(exactAssignments: indices)
            for id in colourOrder(transcriptWords) where indices[Data(id.utf8)] == nil {
                indices[Data(id.utf8)] = allocator.reserve(id)
            }
        }
        let palette = order.map { id in
            let key = Data(id.utf8)
            return NoteSpeaker(id: id, name: labels[key] ?? id, colourIndex: indices[key],
                               provenance: provenance[key] ?? (names[key]?.isNamed == true ? .user : .unnamed))
        }
        let tints = SpeakerTint.assignByID(order, speakers: palette)
        let built = build(transcriptWords) { speaker, _ in
            guard let speaker else { return Template(name: .unknown, tint: .stone) }
            let key = Data(speaker.utf8)
            let name = names[key] ?? unlabeled(1)
            return Template(name: name, tint: tints[key] ?? .stone, auto: automatic.contains(key) && name.isNamed)
        }
        let cards = Dictionary(suggestions.map { (Data($0.speakerID.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        var placedSpeakers = Set<Data>()
        let placed = NoteTranscript(turns: built.turns.map { turn in
            // The latest raw speaker run can start inside a rejoined row or one of its chips. Anchor to the
            // actual word, not the host's row timestamp, while emitting each speaker's card only once.
            var host: SpeakerSuggestion?, inline: [SpeakerSuggestion] = []
            for word in turn.words {
                guard let id = word.speakerID, let card = cards[Data(id.utf8)], names[Data(id.utf8)]?.isNamed != true,
                      ms(word.start) == card.atMs, placedSpeakers.insert(Data(id.utf8)).inserted else { continue }
                let label = names[Data(id.utf8)]?.label ?? DefaultLabels.placeholder(1)
                let suggestion = SpeakerSuggestion(speakerID: id, label: label, voiceID: card.voiceID, voiceName: card.name,
                                                   score: card.score, segmentID: draftSegment, start: word.start)
                if Data(id.utf8) == turn.speakerID.map({ Data($0.utf8) }) { host = suggestion } else { inline.append(suggestion) }
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
        var seen = Set<Data>(), order: [String] = []
        for word in words { if let id = word.speaker, seen.insert(Data(id.utf8)).inserted { order.append(id) } }
        return order
    }

    /// The exact viewer pipeline decides rows. Source indices, not contiguous slices, preserve playback and edits.
    private static func build(_ words: [TranscriptWord], endsBoundedByAudio: Bool = false, template: (String?, Bool) -> Template) -> NoteTranscript {
        let rows = TranscriptTurns.rows(of: words, endsBoundedByAudio: endsBoundedByAudio)
        var seen = Set<Data?>()
        let speakerIDs = Set(words.compactMap(\.speaker))
        func sourceSpeaker(_ id: String?) -> String? {
            id == "Unknown speaker" && !speakerIDs.contains("Unknown speaker") ? nil : id
        }
        let turns = rows.map { row in
            let speaker = sourceSpeaker(row.speaker)
            let made = template(speaker, seen.insert(speaker.map { Data($0.utf8) }).inserted)
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
                return template(speaker, seen.insert(speaker.map { Data($0.utf8) }).inserted).suggestion
            }
            return NoteTurn(id: "w\(indices.min()!)", speakerID: speaker, name: made.name, tint: made.tint,
                            start: row.startMs / 1000, auto: made.auto, source: words, row: row,
                            over: over, suggestion: made.suggestion, inlineSuggestions: inlineSuggestions, passages: passages,
                            automatic: { template(sourceSpeaker($0), false).auto }, template: {
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
         inlineSuggestions: [SpeakerSuggestion], passages: [PassageRef],
         automatic: (String?) -> Bool = { _ in false }, template: (String?) -> (SpeakerName, SpeakerTint)) {
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
                                              nameRange: nameRange, crosstalk: member.crosstalk, auto: automatic(member.speaker)))
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
