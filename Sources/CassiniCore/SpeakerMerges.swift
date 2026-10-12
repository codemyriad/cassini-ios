/**
 * Recording-local speaker aliases: `source -> target` after the person merges two speakers. Recognition keeps its
 * native ids; display and sealing resolve them through the map.
 */
public enum SpeakerMerges {
    /** Where [id] ends after following every alias. */
    public static func resolve(_ id: String, aliases: [String: String]) throws -> String {
        var current = id
        var visited: Set<String> = []
        while let next = aliases[current] {
            try check(visited.insert(current).inserted, "Speaker merge cycle")
            current = next
        }
        return current
    }

    /** [aliases] with [source] merged into [target], flattened so every alias points at its final speaker. */
    public static func merge(_ aliases: [String: String], source: String, into target: String) throws -> [String: String] {
        let from = try resolve(source, aliases: aliases)
        let into = try resolve(target, aliases: aliases)
        try check(from != into, "Speakers are already merged")
        var next = aliases
        next[from] = into
        let merged = next
        return try next.mapValues { try resolve($0, aliases: merged) }
    }

    /** [transcript] with every word's speaker resolved; the words' order and clock never change. */
    public static func apply(_ transcript: Transcript, aliases: [String: String]) throws -> Transcript {
        guard !aliases.isEmpty else { return transcript }
        var merged = transcript
        merged.words = try transcript.words.map { Word(try resolve($0.speaker, aliases: aliases), $0.startMs, $0.endMs, $0.text) }
        return merged
    }

    /** A copy of the recognition record [previous] that also records the person's merges. */
    public static func processing(_ previous: JSONObject?, aliases: [String: String], sourceVariant: String? = nil) -> JSONObject {
        var record = previous ?? JSONObject()
        record["x-speakerMerges"] = .object(JSONObject(aliases.sorted { $0.key < $1.key }.map { ($0.key, JSON.string($0.value)) }))
        record["x-speakerAssignmentEditedBy"] = .string("user")
        if let sourceVariant { record["x-derivedFromTranscript"] = .string(sourceVariant) }
        return record
    }

    /**
     * The voice clips of merged speakers, without raising the per-speaker budget: each resolved speaker keeps at most
     * [budget] samples, and a clip cut shorter than [minimum] is dropped. The defaults are 45 s and 1.5 s at the 16 kHz
     * recognition rate. Speakers are taken in id order, so the result does not depend on dictionary order.
     */
    public static func windows(_ windows: [String: [Range<Int64>]], aliases: [String: String],
                               budget: Int64 = 45 * 16_000, minimum: Int64 = 24_000) throws -> [String: [Range<Int64>]] {
        var result: [String: [Range<Int64>]] = [:]
        var used: [String: Int64] = [:]
        for id in windows.keys.sorted() {
            let speaker = try resolve(id, aliases: aliases)
            for span in windows[id] ?? [] {
                let end = min(span.upperBound, span.lowerBound + budget - used[speaker, default: 0])
                guard end - span.lowerBound >= minimum else { continue }
                result[speaker, default: []].append(span.lowerBound..<end)
                used[speaker, default: 0] += end - span.lowerBound
            }
        }
        return result
    }
}
