import Foundation

/// A consecutive run of background-voice turns folded into a single row in the transcript (D112 / L-86).
public struct BackgroundTurnRun: Identifiable, Hashable, Sendable {
    public let id: String
    public let turns: [NoteTurn]
    /// Number of distinct background voices in this run (at least 1).
    public let voiceCount: Int

    public init(turns: [NoteTurn]) {
        self.id = "bg-\(turns.first?.id ?? "")"
        self.turns = turns
        var seen = Set<Data>()
        for turn in turns {
            if let id = turn.speakerID { seen.insert(Data(id.utf8)) }
        }
        self.voiceCount = max(1, seen.count)
    }
}

/// One display element of a transcript: either a normal turn or a folded run of consecutive background-voice turns.
public enum TranscriptDisplayItem: Identifiable, Hashable, Sendable {
    case turn(NoteTurn)
    case backgroundRun(BackgroundTurnRun)

    public var id: String {
        switch self {
        case .turn(let turn): turn.id
        case .backgroundRun(let run): run.id
        }
    }
}

/// Folds consecutive background-voice turns into single collapsible runs in linear time.
public enum TranscriptFolding {
    public static func items(of turns: [NoteTurn]) -> [TranscriptDisplayItem] {
        var result: [TranscriptDisplayItem] = []
        result.reserveCapacity(turns.count)
        var pending: [NoteTurn] = []
        func flush() {
            guard !pending.isEmpty else { return }
            result.append(.backgroundRun(BackgroundTurnRun(turns: pending)))
            pending.removeAll(keepingCapacity: true)
        }
        for turn in turns {
            if turn.isBackground {
                pending.append(turn)
            } else {
                flush()
                result.append(.turn(turn))
            }
        }
        flush()
        return result
    }
}
