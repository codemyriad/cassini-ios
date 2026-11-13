import Foundation

/// A fixed first-speech slot, revealed when the speaker is named (L-41).
public enum SpeakerTint: CaseIterable, Hashable, Sendable {
    case blue, magenta, cyan, orange, violet, slate, stone

    public static let namedCycle: [SpeakerTint] = [.blue, .magenta, .cyan, .orange, .violet, .slate]

    public static func named(_ colourIndex: Int) -> SpeakerTint {
        namedCycle[((colourIndex % namedCycle.count) + namedCycle.count) % namedCycle.count]
    }

    public static func of(_ speaker: NoteSpeaker, fallbackIndex: Int = 0) -> SpeakerTint {
        speaker.provenance == .unnamed ? .stone : named(speaker.colourIndex ?? fallbackIndex)
    }

    /// Legacy/draft fallback: unnamed speakers reserve their first-speech slot too.
    public static func assign(_ order: [String], isPlaceholder: (String) -> Bool) -> [String: SpeakerTint] {
        var result: [String: SpeakerTint] = [:]
        for id in order where result[id] == nil {
            result[id] = isPlaceholder(id) ? .stone : named(result.count)
        }
        return result
    }

    public static func assign(_ order: [String], labels: [String: String]) -> [String: SpeakerTint] {
        assign(order) { DefaultLabels.isDefault(id: $0, label: labels[$0] ?? $0) }
    }

    public static func assign(_ order: [String], speakers: [NoteSpeaker]) -> [String: SpeakerTint] {
        let exact = assignByID(order, speakers: speakers)
        return Dictionary(order.compactMap { id in exact[Data(id.utf8)].map { (id, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }

    public static func assignByID(_ order: [String], speakers: [NoteSpeaker]) -> [Data: SpeakerTint] {
        let stored = Dictionary(speakers.map { ($0.byteID, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Data: SpeakerTint] = [:]
        for id in order {
            let key = Data(id.utf8)
            guard result[key] == nil else { continue }
            result[key] = stored[key].map { of($0, fallbackIndex: result.count) } ?? .stone
        }
        return result
    }

}

/// Colour allocation follows earliest timed speech; canonical transcript/render order stays untouched.
public enum SpeakerColourOrder {
    public static func earliest<S: Sequence>(_ values: S, id: (S.Element) -> String?,
                                             start: (S.Element) -> Double) -> [String] {
        var first: [Data: (id: String, time: Double, position: Int)] = [:]
        for (position, value) in values.enumerated() {
            guard let speaker = id(value) else { continue }
            let key = Data(speaker.utf8)
            let raw = start(value), time = raw.isFinite ? raw : .infinity
            if let previous = first[key] {
                if time < previous.time { first[key] = (speaker, time, previous.position) }
            } else { first[key] = (speaker, time, position) }
        }
        return first.keys.sorted {
            let a = first[$0]!, b = first[$1]!
            return a.time != b.time ? a.time < b.time : a.position < b.position
        }.map { first[$0]!.id }
    }

    public static func segments(_ segments: [TranscriptSegment]) -> [String] {
        earliest(segments, id: { $0.speakerID }, start: { segment in
            segment.words.lazy.map(\.start).filter(\.isFinite).min() ?? segment.start
        })
    }

    public static func words(_ words: [TranscriptWord]) -> [String] {
        earliest(words, id: { $0.speaker }, start: { $0.start })
    }
}
