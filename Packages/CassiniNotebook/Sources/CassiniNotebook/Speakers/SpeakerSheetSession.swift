import Foundation

/// Pure multi-speaker session for the Name a speaker sheet (D112 / L-86): keeps every speaker's form in memory
/// while switching between speakers in the top row, then applies all pending changes in one Save with one Undo toast.
public struct SpeakerSheetSession: Hashable, Sendable {
    public struct RowSpeaker: Identifiable, Hashable, Sendable {
        public var speakerID: String
        public var byteID: Data { Data(speakerID.utf8) }
        public var id: Data { byteID }
        public var label: String
        public var ordinal: Int
        public var tint: SpeakerTint
        public var isBackground: Bool
        public var provenance: NoteSpeaker.Provenance?

        public init(speakerID: String, label: String, ordinal: Int, tint: SpeakerTint,
                    isBackground: Bool = false, provenance: NoteSpeaker.Provenance? = nil) {
            self.speakerID = speakerID; self.label = label; self.ordinal = ordinal
            self.tint = tint; self.isBackground = isBackground; self.provenance = provenance
        }
    }

    public struct BatchWrite: Hashable, Sendable {
        public var speakerID: String
        public var effects: [NamingEffect]
        public init(speakerID: String, effects: [NamingEffect]) {
            self.speakerID = speakerID; self.effects = effects
        }
    }

    public struct SaveSummary: Hashable, Sendable {
        public enum ToastKind: Hashable, Sendable {
            /// "{name} is now a background voice"
            case singleBackground(name: String)
            /// "Named {name} · {n} background voices"
            case namedAndBackground(name: String, count: Int)
            /// "{n} background voices"
            case multipleBackground(count: Int)
        }

        public var namedSpeakers: [String]
        public var markedBackground: [String]
        public var unmarkedBackground: [String]

        public init(namedSpeakers: [String] = [], markedBackground: [String] = [], unmarkedBackground: [String] = []) {
            self.namedSpeakers = namedSpeakers
            self.markedBackground = markedBackground
            self.unmarkedBackground = unmarkedBackground
        }

        public var toastKind: ToastKind? {
            if markedBackground.count == 1 && namedSpeakers.isEmpty {
                return .singleBackground(name: markedBackground[0])
            }
            if !markedBackground.isEmpty && !namedSpeakers.isEmpty {
                return .namedAndBackground(name: namedSpeakers[0], count: markedBackground.count)
            }
            if markedBackground.count >= 2 && namedSpeakers.isEmpty {
                return .multipleBackground(count: markedBackground.count)
            }
            return nil
        }
    }

    /// Speakers in the order of the names under the meeting title.
    public var roster: [RowSpeaker]
    public var selectedSpeakerID: String
    public var drafts: [Data: NamingState] = [:]

    public init(roster: [RowSpeaker], selectedSpeakerID: String) {
        self.roster = roster
        self.selectedSpeakerID = selectedSpeakerID
    }

    /// Builds the ordered roster for a note, matching the canonical word order under the meeting title.
    public static func roster(for note: Note, voices: [SavedVoice] = []) -> [RowSpeaker] {
        let transcript = NoteTranscripts.sealed(note, voices: voices)
        return roster(from: transcript.allHeaderSpeakers, speakers: note.speakers ?? [])
    }

    /// Builds the ordered roster from already-prepared `allHeaderSpeakers` without rebuilding the transcript.
    public static func roster(from allHeaderSpeakers: [TranscriptSpeaker], speakers: [NoteSpeaker]) -> [RowSpeaker] {
        let catalog = Dictionary(speakers.map { ($0.byteID, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [RowSpeaker] = []
        rows.reserveCapacity(max(allHeaderSpeakers.count, speakers.count))
        var seen = Set<Data>()
        for (ordinal, speaker) in allHeaderSpeakers.enumerated() {
            seen.insert(speaker.byteID)
            let stored = catalog[speaker.byteID]
            rows.append(RowSpeaker(
                speakerID: speaker.id,
                label: stored?.name ?? speaker.name.label,
                ordinal: ordinal,
                tint: speaker.tint,
                isBackground: stored?.background ?? speaker.background,
                provenance: stored?.provenance
            ))
        }
        // Include any catalog speaker without spoken words at the end, in catalog order.
        for speaker in speakers where seen.insert(speaker.byteID).inserted {
            let ordinal = rows.count
            let tint = speaker.colourIndex.map { SpeakerTint.named($0) } ?? .stone
            rows.append(RowSpeaker(
                speakerID: speaker.id,
                label: speaker.name,
                ordinal: ordinal,
                tint: tint,
                isBackground: speaker.background,
                provenance: speaker.provenance
            ))
        }
        return rows
    }

    /// Lightweight O(speakers) fallback roster from the note's speaker catalog while canonical order prepares off-main.
    public static func catalogRoster(for speakers: [NoteSpeaker]) -> [RowSpeaker] {
        speakers.enumerated().map { ordinal, speaker in
            RowSpeaker(
                speakerID: speaker.id,
                label: speaker.name,
                ordinal: ordinal,
                tint: speaker.colourIndex.map { SpeakerTint.named($0) } ?? .stone,
                isBackground: speaker.background,
                provenance: speaker.provenance
            )
        }
    }

    public mutating func updateRoster(_ roster: [RowSpeaker]) {
        self.roster = roster
    }

    public var currentState: NamingState? { drafts[Data(selectedSpeakerID.utf8)] }

    public mutating func setLoaded(_ input: NamingInput) {
        let key = Data(input.speakerID.utf8)
        if drafts[key] == nil {
            drafts[key] = SpeakerNaming.open(input)
        }
    }

    public mutating func select(_ speakerID: String) {
        guard roster.contains(where: { $0.byteID == Data(speakerID.utf8) }) else { return }
        selectedSpeakerID = speakerID
    }

    /// Live row items reflecting unsaved draft edits (name and background toggle).
    public var displayedRoster: [RowSpeaker] {
        roster.map { item in
            guard let draft = drafts[item.byteID] else { return item }
            var copy = item
            copy.isBackground = draft.isBackground
            let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.isBackground && !trimmed.isEmpty {
                copy.label = trimmed
                copy.provenance = .user
            }
            return copy
        }
    }

    /// The first speaker whose draft is blocked by an unanswered question (current speaker first).
    public var blockingSpeakerID: String? {
        if let current = currentState, SpeakerNaming.saveState(current) == .blockedByQuestion {
            return selectedSpeakerID
        }
        for item in roster {
            if let draft = drafts[item.byteID], SpeakerNaming.saveState(draft) == .blockedByQuestion {
                return item.speakerID
            }
        }
        return nil
    }

    /// Combined Save button state across all speakers in the session.
    public var saveState: SaveState {
        if blockingSpeakerID != nil { return .blockedByQuestion }
        for item in roster {
            if let draft = drafts[item.byteID], SpeakerNaming.saveState(draft) == .enabled {
                return .enabled
            }
        }
        if let current = currentState, SpeakerNaming.saveState(current) == .enabled {
            return .enabled
        }
        return .disabled
    }

    /// Collects all pending writes across every modified speaker in roster order, plus the Undo toast summary.
    public func pendingSave(displayLabel: (NamingInput) -> String = { $0.label }) -> (writes: [BatchWrite], summary: SaveSummary) {
        var writes: [BatchWrite] = []
        var named: [String] = []
        var markedBg: [String] = []
        var unmarkedBg: [String] = []

        var orderedIDs = roster.map(\.speakerID)
        if !orderedIDs.contains(where: { Data($0.utf8) == Data(selectedSpeakerID.utf8) }) {
            orderedIDs.append(selectedSpeakerID)
        }

        for id in orderedIDs {
            guard let draft = drafts[Data(id.utf8)], SpeakerNaming.saveState(draft) == .enabled else { continue }
            let result = SpeakerNaming.reduce(draft, .save)
            let speakerWrites = result.writes
            guard !speakerWrites.isEmpty else { continue }
            writes.append(BatchWrite(speakerID: id, effects: speakerWrites))

            if draft.isBackground && !draft.initialBackground {
                markedBg.append(displayLabel(draft.input))
            } else if !draft.isBackground && draft.initialBackground {
                unmarkedBg.append(displayLabel(draft.input))
            }
            if !draft.isBackground {
                let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != draft.input.namedLabel {
                    named.append(trimmed)
                }
            }
        }

        return (writes, SaveSummary(namedSpeakers: named, markedBackground: markedBg, unmarkedBackground: unmarkedBg))
    }
}
