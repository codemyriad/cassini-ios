import CassiniCore
import Foundation

/// The draft transcript of a running or paused job with its draft names (Android's `DraftView`, features.md 3.1).
public enum DraftView {
    /// `draft` (the job's raw speaker ids) with `names`: merges applied, each speaker's label by precedence (the user's
    /// name, then the automatic live match's name, then the placeholder numbered by first word), and the suggestion
    /// cards while naming is open. `voiceNames` are the saved voices as they are now (id to name).
    public static func build(_ draft: DraftState, names: DraftNames, voiceNames: [UUID: String]) -> DraftState {
        build(draft, names: names, voiceNames: voiceNames, reserveColours: { $0.observingWords($1) })
    }

    /// The injected legacy fallback lets pure tests count allocations without a global rendering probe.
    static func build(_ draft: DraftState, names: DraftNames, voiceNames: [UUID: String],
                      reserveColours: (DraftNames, [DraftWord]) -> DraftNames) -> DraftState {
        let hints = draft.colourIndices.merging(names.colourIndices) { _, stored in stored }
        var missingColour = false
        let words = names.merges.isEmpty ? draft.words : draft.words.map { word in
            let rawID = word.speaker.isEmpty ? NoteTranscripts.draftOneVoice : word.speaker
            if hints[rawID] == nil { missingColour = true }
            var merged = word
            merged.speaker = names.resolve(word.speaker)
            return merged
        }
        var labels: [String: String] = [:]
        var provenance: [String: NoteSpeaker.Provenance] = [:]
        var automatic = Set<String>(), placeholders = Set<String>()
        var seen = Set<String>()
        for word in words {
            if names.merges.isEmpty {
                let rawID = word.speaker.isEmpty ? NoteTranscripts.draftOneVoice : word.speaker
                if hints[rawID] == nil { missingColour = true }
            }
            guard !word.speaker.isEmpty && seen.insert(word.speaker).inserted else { continue }
            // A stored placeholder (a names.json written elsewhere could hold one) is not a name.
            if let named = names.labels[word.speaker],
               names.explicitNames.contains(word.speaker) || !DefaultLabels.isDefault(id: word.speaker, label: named) {
                labels[word.speaker] = named
                provenance[word.speaker] = .user
            } else if let auto = names.automatic[word.speaker] {
                labels[word.speaker] = auto
                provenance[word.speaker] = .recognised
                automatic.insert(word.speaker)
            } else {
                labels[word.speaker] = DefaultLabels.placeholder(seen.count)
                placeholders.insert(word.speaker)
                provenance[word.speaker] = .unnamed
            }
        }
        var indices = hints
        if missingColour {
            var legacy = names
            legacy.colourIndices = hints
            indices = reserveColours(legacy, draft.words).colourIndices
        }
        let cards = draft.namingOpen ? suggestions(words, placeholders: placeholders, names: names, voiceNames: voiceNames) : []
        return DraftState(words: words, tentativeFromMs: draft.tentativeFromMs, namingOpen: draft.namingOpen,
                          labels: labels, automatic: automatic, suggestions: cards,
                          colourIndices: indices, provenance: provenance)
    }

    /// "Is this Luca?" for each placeholder speaker with a live suggested match to a voice that still exists and was not
    /// rejected, at the start of that speaker's latest turn.
    static func suggestions(_ words: [DraftWord], placeholders: Set<String>, names: DraftNames,
                            voiceNames: [UUID: String]) -> [DraftSuggestion] {
        guard !placeholders.isEmpty, !names.live.isEmpty else { return [] }
        var latestTurn: [String: Int64] = [:]
        var previous: String?
        for word in words {
            if word.speaker != previous { latestTurn[word.speaker] = word.startMs }
            previous = word.speaker
        }
        return latestTurn.keys.filter(placeholders.contains).compactMap { id -> DraftSuggestion? in
            guard let match = names.live[id], match.state == .suggested, let name = voiceNames[match.voice],
                  !(names.rejected[id] ?? []).contains(match.voice), let at = latestTurn[id] else { return nil }
            return DraftSuggestion(speakerID: id, voiceID: match.voice, name: name, score: match.score, atMs: at)
        }.sorted { ($0.atMs, $0.speakerID) < ($1.atMs, $1.speakerID) }
    }
}
