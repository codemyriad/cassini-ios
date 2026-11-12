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
        let stored = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: SpeakerTint] = [:]
        for id in order where result[id] == nil {
            result[id] = stored[id].map { of($0, fallbackIndex: result.count) } ?? .stone
        }
        return result
    }
}
