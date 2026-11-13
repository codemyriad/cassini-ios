import CassiniCore
import Foundation

/// A live voice match of a draft speaker (Android's `Match` in `names.json`): the saved voice, its score and whether
/// it names the speaker by itself (`auto`), is only offered (`suggested`) or was confirmed by the user.
public struct LiveMatch: Hashable, Sendable {
    public enum State: String, Codable, Sendable { case auto = "AUTO", suggested = "SUGGESTED", confirmed = "CONFIRMED" }
    public var voice: UUID
    public var score: Float
    public var state: State
    public init(_ voice: UUID, _ score: Float, _ state: State) { self.voice = voice; self.score = score; self.state = state }
}

extension LiveMatch: Codable {
    private enum CodingKeys: String, CodingKey { case voice, score, state }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice = try c.decode(UUID.self, forKey: .voice)
        score = try c.decode(Float.self, forKey: .score)
        state = try c.decode(State.self, forKey: .state)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(voice, forKey: .voice)
        // The Float's shortest decimal form, so 0.61 is written as 0.61, as Android writes it.
        try c.encode(Double("\(score)") ?? Double(score), forKey: .score)
        try c.encode(state, forKey: .state)
    }
}

/// `work/names.json` beside a streaming job's checkpoint: the draft speaker names of a running or paused job (Android's
/// `CheckpointNames`). `labels` are the names the user gave, `merges` the speaker aliases (`SpeakerMerges`),
/// `remembered` the voice to enrol each speaker's print into once the job is done (`.new` makes a new voice),
/// `automatic` the name of an automatic live match, `generation` the Forget everyone generation the remember choices
/// were made in, `live` the latest live match per speaker and `rejected` the voices the user answered "Not X" to.
///
/// Every change goes through one of the pure reducers (`rename`, `remember`, `confirm`, `reject`, `merge`,
/// `applyLive`), which take the speaker id as shown (they resolve `merges`) and never fail for an unknown speaker. A
/// confirmed live match exists only while `remembered` holds its voice.
public struct DraftNames: Hashable, Sendable {
    public var labels: [String: String]
    /// Append-only first-speech reservations, including speakers later merged away.
    public var colourIndices: [String: Int]
    /// Explicit naming distinguishes a literal name "Speaker 1" from a legacy placeholder label.
    public var explicitNames: Set<String>
    public var merges: [String: String]
    public var remembered: [String: DraftVoice]
    public var automatic: [String: String]
    public var generation: Int
    public var live: [String: LiveMatch]
    /// Each speaker's rejected voices, in the order they were rejected.
    public var rejected: [String: [UUID]]

    /// The names of a draft nobody has named yet.
    public static let empty = DraftNames()

    public init(labels: [String: String] = [:], merges: [String: String] = [:], remembered: [String: DraftVoice] = [:],
                automatic: [String: String] = [:], generation: Int = 0, live: [String: LiveMatch] = [:],
                rejected: [String: [UUID]] = [:], colourIndices: [String: Int] = [:], explicitNames: Set<String> = []) {
        self.labels = labels; self.merges = merges; self.remembered = remembered; self.automatic = automatic
        self.generation = generation; self.live = live; self.rejected = rejected
        self.colourIndices = colourIndices; self.explicitNames = explicitNames
    }

    /// Reserve new raw speaker IDs before applying aliases; existing reservations never move.
    public func observingWords(_ words: [DraftWord]) -> DraftNames {
        var next = self
        var index = (colourIndices.values.max() ?? -1) + 1
        let order = SpeakerColourOrder.earliest(words, id: { $0.speaker.isEmpty ? NoteTranscripts.draftOneVoice : $0.speaker },
                                                start: { Double($0.startMs) })
        for id in order where next.colourIndices[id] == nil {
            next.colourIndices[id] = index
            index += 1
        }
        return next
    }

    /// Whether the job should still try to match `speakerID` live: no confirmed match, no user label, not merged into
    /// another speaker.
    public func openForLive(_ speakerID: String) -> Bool { merges[speakerID] == nil && !guarded(speakerID) }

    /// The `excluded` of `VoiceMatcher.match` for `speakers`: each speaker's rejected voices, plus the voices confirmed
    /// for another speaker (a person names one speaker).
    public func excluded(_ speakers: some Collection<String>) -> [String: Set<UUID>] {
        let confirmed = live.filter { $0.value.state == .confirmed }
        var result: [String: Set<UUID>] = [:]
        for id in speakers {
            let voices = Set(rejected[id] ?? []).union(confirmed.filter { $0.key != id }.map(\.value.voice))
            if !voices.isEmpty { result[id] = voices }
        }
        return result
    }

    /// The user named `speakerID` `name`. A blank name removes the label and the remember choice. The
    /// automatic name and an unconfirmed live match go: the user's name wins over them.
    public func rename(_ speakerID: String, _ name: String) -> DraftNames {
        let id = resolve(speakerID)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleared = self
        cleared.automatic[id] = nil
        if let match = live[id], match.state != .confirmed { cleared.live[id] = nil }
        if trimmed.isEmpty {
            cleared.labels[id] = nil
            cleared.explicitNames.remove(id)
            return cleared.remember(id, nil, generation: generation)
        }
        cleared.labels[id] = trimmed
        cleared.explicitNames.insert(id)
        return cleared
    }

    /// The Remember choice for `speakerID` (nil for none). Another generation drops the earlier choices first (the
    /// voices were forgotten since). A confirmed live match to another voice goes.
    public func remember(_ speakerID: String, _ voice: DraftVoice?, generation: Int) -> DraftNames {
        let id = resolve(speakerID)
        var next = self
        if generation != self.generation { next.remembered = [:] }
        next.remembered[id] = voice
        next.generation = generation
        next.live = next.live.filter { key, match in
            match.state != .confirmed || next.remembered[key] == .saved(match.voice)
        }
        return next
    }

    /// "Yes, Luca": `speakerID` is the saved voice `voice` called `name`, with `score`. Another speaker's unconfirmed
    /// live match to the same voice goes, as does a rejection of it.
    public func confirm(_ speakerID: String, voice: UUID, name: String, generation: Int, score: Float) -> DraftNames {
        let id = resolve(speakerID)
        var next = remember(id, .saved(voice), generation: generation)
        let others = next.live.filter { $0.key != id && $0.value.voice == voice && $0.value.state != .confirmed }.keys
        next.labels[id] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.explicitNames.insert(id)
        next.automatic[id] = nil
        for other in others {
            next.automatic[other] = nil
            next.live[other] = nil
        }
        next.live[id] = LiveMatch(voice, score, .confirmed)
        let rejections = (next.rejected[id] ?? []).filter { $0 != voice }
        next.rejected[id] = rejections.isEmpty ? nil : rejections
        return next
    }

    /// "Not Luca": `voice` is never suggested for `speakerID` again. Its live match, its automatic name and a remember
    /// choice of it go; with `voiceName`, a label or automatic name equal to it goes too. Nothing is unenrolled: a
    /// draft has enrolled nothing yet.
    public func reject(_ speakerID: String, voice: UUID, voiceName: String? = nil) -> DraftNames {
        let id = resolve(speakerID)
        let matched = live[id]?.voice == voice
        let named = voiceName != nil && automatic[id] == voiceName
        var next = remembered[id] == .saved(voice) ? remember(id, nil, generation: generation) : self
        if let voiceName, next.labels[id] == voiceName {
            next.labels[id] = nil
            next.explicitNames.remove(id)
        }
        if matched || named { next.automatic[id] = nil }
        if matched { next.live[id] = nil }
        var rejections = next.rejected[id] ?? []
        if !rejections.contains(voice) { rejections.append(voice) }
        next.rejected[id] = rejections
        return next
    }

    /// Shows everything `source` said as `target` (`SpeakerMerges.merge`; throws when they are one speaker already).
    /// The source's label, remember choice, automatic name, live match and rejections go; `targetLabel`, when given,
    /// becomes the target's label.
    public func merge(_ source: String, into target: String, targetLabel: String? = nil) throws -> DraftNames {
        let from = resolve(source)
        let into = resolve(target)
        var next = self
        next.merges = try SpeakerMerges.merge(merges, source: source, into: target)
        next.labels[from] = nil
        next.explicitNames.remove(from)
        if let targetLabel, !targetLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next.labels[into] = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        next.remembered[from] = nil
        next.automatic[from] = nil
        next.live[from] = nil
        next.rejected[from] = nil
        return next
    }

    /// One round of live matching: `matches` covers every speaker with a print, so a speaker without an entry has no
    /// match now; `names` are the voices' names, for the automatic names. Speakers not open for live matching keep
    /// their state. A match is ignored when the user rejected that voice for that speaker, or when the voice is
    /// confirmed for another speaker. A round worked out from the state before a user action gives the same result
    /// applied before or after it.
    public func applyLive(_ matches: [String: LiveMatch], names: [UUID: String]) -> DraftNames {
        let confirmed = Set(live.values.filter { $0.state == .confirmed }.map(\.voice))
        let accepted = matches.filter { id, match in
            openForLive(id) && !(rejected[id] ?? []).contains(match.voice) && !confirmed.contains(match.voice)
                && (match.state == .auto || match.state == .suggested)
        }
        var next = self
        next.automatic = automatic.filter { !openForLive($0.key) }
        for (id, match) in accepted where match.state == .auto {
            if let name = names[match.voice] { next.automatic[id] = name }
        }
        next.live = live.filter { !openForLive($0.key) }.merging(accepted) { _, new in new }
        return next
    }

    /// The names without anything that names `voice` (Forget of one saved voice, Android's `forgetInDraft`): its live
    /// matches, the automatic names they gave, the Remember choices and the rejections of it.
    public func forgetting(_ voice: UUID) -> DraftNames {
        let speakers = Set(live.filter { $0.value.voice == voice }.keys)
        var next = self
        next.live = live.filter { !speakers.contains($0.key) }
        next.automatic = automatic.filter { !speakers.contains($0.key) }
        next.remembered = remembered.filter { $0.value != .saved(voice) }
        next.rejected = rejected.compactMapValues { voices in
            let kept = voices.filter { $0 != voice }
            return kept.isEmpty ? nil : kept
        }
        return next
    }

    /// The names after Forget everyone moved the generation to `generation`: no live match, Remember choice, automatic
    /// name or rejection is left; the labels and merges stay.
    public func forgettingEveryone(generation: Int) -> DraftNames {
        DraftNames(labels: labels, merges: merges, generation: generation, colourIndices: colourIndices, explicitNames: explicitNames)
    }

    /// The voice clips of each shown speaker: `windows` with the merges applied, without raising a speaker's 45 s
    /// budget (`SpeakerMerges.windows`). Damaged merges leave the windows as they are.
    public func merged(_ windows: [String: [PrintWindow]]) -> [String: [PrintWindow]] {
        guard !merges.isEmpty else { return windows }
        let ranges = windows.mapValues { $0.map { Int64($0.startSample)..<Int64($0.endSample) } }
        guard let merged = try? SpeakerMerges.windows(ranges, aliases: merges) else { return windows }
        return merged.mapValues { $0.map { PrintWindow(Int($0.lowerBound), Int($0.upperBound)) } }
    }

    /// `speakerID` after following every merge; itself when it is not merged (or the merges are damaged).
    public func resolve(_ speakerID: String) -> String { (try? SpeakerMerges.resolve(speakerID, aliases: merges)) ?? speakerID }

    private func guarded(_ id: String) -> Bool { live[id]?.state == .confirmed || labels[id] != nil }
}

// MARK: - The Name a speaker sheet

extension DraftNames {
    /// The names after the draft effects of the Name a speaker sheet or a suggestion card (Android's
    /// `NoteViewModel.draftName`, `DraftNaming.merge` and the draft's `reject`), with the Forget everyone `generation`
    /// now. A save that binds a saved voice confirms it; any other names the speaker and records the Remember choice.
    /// The other effects are not the draft's and change nothing here.
    public func applying(_ effects: [NamingEffect], generation: Int) -> DraftNames {
        var names = self
        for effect in effects {
            switch effect {
            case .draftName(let id, let name, let voice, let confirm, let score):
                if confirm, case .saved(let saved)? = voice {
                    names = names.confirm(id, voice: saved, name: name, generation: generation, score: score)
                } else {
                    names = names.rename(id, name).remember(id, voice, generation: generation)
                }
            case .mergeDraft(let source, let target, let label):
                names = (try? names.merge(source, into: target, targetLabel: label)) ?? names
            case .reject(let id, let voice, let voiceName, _, _, true):
                names = names.reject(id, voice: voice, voiceName: voiceName)
            default:
                break
            }
        }
        return names
    }

    /// The speaker's live match as the Name a speaker sheet takes it.
    public func match(_ speakerID: String) -> VoiceMatchState {
        guard let match = live[resolve(speakerID)] else { return .unmatched }
        switch match.state {
        case .auto: return .auto(voice: match.voice, score: match.score)
        case .suggested: return .suggested(voice: match.voice, score: match.score)
        case .confirmed: return .confirmed(voice: match.voice, score: match.score)
        }
    }
}

// MARK: - names.json

extension DraftNames: Codable {
    /// The members Android's 0.1.0 writes; `live` and `rejected` are written only when not empty.
    public static let keys: Set<String> = ["labels", "merges", "remembered", "automatic", "generation"]
    public static let optionalKeys: Set<String> = ["live", "rejected", "colourIndices", "explicitNames"]

    private enum CodingKeys: String, CodingKey { case labels, merges, remembered, automatic, generation, live, rejected, colourIndices, explicitNames }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decode([String: String].self, forKey: .labels)
        merges = try c.decode([String: String].self, forKey: .merges)
        remembered = try (c.decodeIfPresent([String: String].self, forKey: .remembered) ?? [:]).mapValues { value in
            guard let voice = DraftVoice(stored: value) else {
                throw DecodingError.dataCorruptedError(forKey: .remembered, in: c, debugDescription: "Not a voice: \(value)")
            }
            return voice
        }
        automatic = try c.decodeIfPresent([String: String].self, forKey: .automatic) ?? [:]
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        live = try c.decodeIfPresent([String: LiveMatch].self, forKey: .live) ?? [:]
        rejected = try c.decodeIfPresent([String: [UUID]].self, forKey: .rejected) ?? [:]
        colourIndices = try c.decodeIfPresent([String: Int].self, forKey: .colourIndices) ?? [:]
        guard colourIndices.values.allSatisfy({ (0...9_007_199_254_740_991).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .colourIndices, in: c, debugDescription: "Invalid colour index")
        }
        explicitNames = try c.decodeIfPresent(Set<String>.self, forKey: .explicitNames) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(labels, forKey: .labels)
        try c.encode(merges, forKey: .merges)
        try c.encode(remembered.mapValues(\.stored), forKey: .remembered)
        try c.encode(automatic, forKey: .automatic)
        try c.encode(generation, forKey: .generation)
        if !live.isEmpty { try c.encode(live, forKey: .live) }
        if !rejected.isEmpty { try c.encode(rejected, forKey: .rejected) }
        if !colourIndices.isEmpty { try c.encode(colourIndices, forKey: .colourIndices) }
        if !explicitNames.isEmpty { try c.encode(explicitNames.sorted(), forKey: .explicitNames) }
    }

    /// Compact JSON with sorted members.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension DraftVoice {
    /// As `names.json` stores it: "" for a new voice (Android's), else the saved voice's id.
    public var stored: String {
        switch self {
        case .new: ""
        case .saved(let id): id.uuidString
        }
    }

    public init?(stored: String) {
        if stored.isEmpty { self = .new } else if let id = UUID(uuidString: stored) { self = .saved(id) } else { return nil }
    }
}
