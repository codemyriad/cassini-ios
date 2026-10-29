import Foundation

/// Name comparison and the voice list of the Name a speaker sheet.
///
/// Names are compared after `normalise`: "Élodie", " elodie " and "ELODIE" are the same name.
public enum NameMatch {
    /// One row of "Saved voices, closest first". `score` is nil for a stale voice or without a print.
    public struct Ranked: Hashable, Sendable {
        public var voice: SavedVoice
        public var score: Float?
        public var stale: Bool
        public var likely: Bool
    }

    /// `name` trimmed, with runs of white space as one space, decomposed without combining marks, and case folded
    /// (upper case, then lower case, so that "ß" and "SS" agree). Locale independent.
    public static func normalise(_ name: String) -> String {
        let collapsed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var scalars = String.UnicodeScalarView()
        for scalar in collapsed.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            scalars.append(scalar)
        }
        return String(scalars).uppercased().lowercased()
    }

    /// The first word of `name`, normalised.
    public static func firstWord(_ name: String) -> String {
        String(normalise(name).split(separator: " ", maxSplits: 1).first ?? "")
    }

    /// Whether two names are the same after `normalise`.
    public static func same(_ a: String, _ b: String) -> Bool { normalise(a) == normalise(b) }

    /// The saved voices that `typed` may mean: the normalised typed name equals a voice's full name or its first word.
    /// "Anna" matches "Anna Ricci"; "Anna Ricci" does not match "Anna". A blank name matches nothing.
    public static func samePersonCandidates(_ typed: String, voices: [SavedVoice]) -> [SavedVoice] {
        let name = normalise(typed)
        guard !name.isEmpty else { return [] }
        return voices.filter { normalise($0.name) == name || firstWord($0.name) == name }
    }

    /// The candidate to ask about: the highest score (a missing score is lowest), ties in `alphabetical` order.
    public static func pick(_ candidates: [SavedVoice], scores: [UUID: Float]) -> SavedVoice? {
        candidates.min { a, b in
            let x = scores[a.id] ?? -.infinity, y = scores[b.id] ?? -.infinity
            return x == y ? alphabetical(a, b) : x > y
        }
    }

    /// `samePersonCandidates` then `pick`.
    public static func samePerson(_ typed: String, voices: [SavedVoice], scores: [UUID: Float]) -> SavedVoice? {
        pick(samePersonCandidates(typed, voices: voices), scores: scores)
    }

    /// The cosine of `print` with each voice it can be compared with; none without a print.
    public static func scores(_ print: SpeakerPrint?, voices: [SavedVoice]) -> [UUID: Float] {
        guard let print else { return [:] }
        var scores: [UUID: Float] = [:]
        for voice in voices { scores[voice.id] = voice.score(print) }
        return scores
    }

    /// The saved voices for the sheet. With a `print`: current voices by score (highest first, ties alphabetical), then
    /// stale voices alphabetically without a score. Without a print: current voices, then stale voices, each
    /// alphabetical; `model` is then the current model, for staleness. Only the first row can be "Likely", and only
    /// when its score is at least `suggest`.
    public static func rank(_ print: SpeakerPrint?, voices: [SavedVoice], model: String = VoiceprintModel.sha256,
                            suggest: Float) -> [Ranked] {
        let model = print?.model ?? model
        let dimension = print?.vector.count
        let stale = voices.filter { VoiceStaleness.isStale($0, model: model, dimension: dimension) }
        let current = voices.filter { !VoiceStaleness.isStale($0, model: model, dimension: dimension) }
        let scores = scores(print, voices: current)
        let scored = current.map { Ranked(voice: $0, score: scores[$0.id], stale: false, likely: false) }.sorted { a, b in
            let x = a.score ?? -.infinity, y = b.score ?? -.infinity
            return x == y ? alphabetical(a.voice, b.voice) : x > y
        }
        var rows = scored + stale.sorted(by: alphabetical).map { Ranked(voice: $0, score: nil, stale: true, likely: false) }
        if let score = rows.first?.score, score >= suggest { rows[0].likely = true }
        return rows
    }

    /// Alphabetical by normalised name, then by the name as written, then by id, so the order is total.
    public static func alphabetical(_ a: SavedVoice, _ b: SavedVoice) -> Bool {
        (normalise(a.name), a.name, a.id.uuidString) < (normalise(b.name), b.name, b.id.uuidString)
    }
}
