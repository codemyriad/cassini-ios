import CassiniCore
import Foundation

/// The draft transcript of a running or paused job with its draft names (Android's `DraftView`, features.md 3.1).
public enum DraftView {
    /// `draft` (the job's raw speaker ids) with `names`: merges applied, each speaker's label by precedence (the user's
    /// name, then the automatic live match's name, then the placeholder numbered by first word), and the suggestion
    /// cards while naming is open. `voiceNames` are the saved voices as they are now (id to name).
    public static func build(_ draft: DraftState, names: DraftNames, voiceNames: [UUID: String]) -> DraftState {
        let words = names.merges.isEmpty ? draft.words : draft.words.map { word in
            var merged = word
            merged.speaker = names.resolve(word.speaker)
            return merged
        }
        var labels: [String: String] = [:]
        var automatic = Set<String>(), placeholders = Set<String>()
        var seen = Set<String>()
        for word in words where !word.speaker.isEmpty && seen.insert(word.speaker).inserted {
            // A stored placeholder (a names.json written elsewhere could hold one) is not a name.
            if let named = names.labels[word.speaker], !DefaultLabels.isDefault(id: word.speaker, label: named) {
                labels[word.speaker] = named
            } else if let auto = names.automatic[word.speaker] {
                labels[word.speaker] = auto
                automatic.insert(word.speaker)
            } else {
                labels[word.speaker] = DefaultLabels.placeholder(seen.count)
                placeholders.insert(word.speaker)
            }
        }
        let cards = draft.namingOpen ? suggestions(words, placeholders: placeholders, names: names, voiceNames: voiceNames) : []
        return DraftState(words: words, tentativeFromMs: draft.tentativeFromMs, namingOpen: draft.namingOpen,
                          labels: labels, automatic: automatic, suggestions: cards)
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
