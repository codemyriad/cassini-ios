import Foundation

/// The colour of a speaker's label in the transcript (Android `SpeakerTint`). A placeholder speaker is always `stone`
/// ("not named yet"). Named speakers cycle six decided palette roles in order of their first turn; placeholder
/// speakers take no slot. The app maps each value to its colour.
public enum SpeakerTint: CaseIterable, Hashable, Sendable {
    case vermilion, brown, yellow, sky, green, plum, stone

    /// The cycle of named speakers.
    public static let namedCycle: [SpeakerTint] = [.vermilion, .brown, .yellow, .sky, .green, .plum]

    /// The tint of the named speaker at `namedIndex` (from 0) among the named speakers only.
    public static func named(_ namedIndex: Int) -> SpeakerTint {
        let count = namedCycle.count
        return namedCycle[((namedIndex % count) + count) % count]
    }

    /// The tint of each speaker in `order` (speaker ids in order of their first turn). `isPlaceholder` tells a speaker
    /// without a name.
    public static func assign(_ order: [String], isPlaceholder: (String) -> Bool) -> [String: SpeakerTint] {
        var result: [String: SpeakerTint] = [:]
        var named = 0
        for id in order where result[id] == nil {
            if isPlaceholder(id) {
                result[id] = .stone
            } else {
                result[id] = Self.named(named)
                named += 1
            }
        }
        return result
    }

    /// `assign` with display `labels`; a missing label is a placeholder (`DefaultLabels.isDefault`).
    public static func assign(_ order: [String], labels: [String: String]) -> [String: SpeakerTint] {
        assign(order) { id in DefaultLabels.isDefault(id: id, label: labels[id] ?? id) }
    }
}
