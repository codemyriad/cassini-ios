import Foundation

/// When a match names a speaker automatically, when it is only offered, and how far ahead of a rival it must be.
public struct VoiceThresholds: Hashable, Sendable {
    public var automatic: Float
    public var suggest: Float
    public var margin: Float
    public init(automatic: Float, suggest: Float, margin: Float) {
        self.automatic = automatic; self.suggest = suggest; self.margin = margin
    }

    /// For the iOS embedding model (FluidAudio). Deliberately higher than Android's CAM++ values (0.72, 0.50, 0.08),
    /// which must never be reused here.
    public static let ios = VoiceThresholds(automatic: 0.85, suggest: 0.65, margin: 0.12)
}

/// The best saved voice for a speaker: its score, and whether it is strong enough to name the speaker by itself.
public struct VoiceMatch: Hashable, Sendable {
    public var voiceID: UUID
    public var score: Float
    public var automatic: Bool
    public init(voiceID: UUID, score: Float, automatic: Bool) {
        self.voiceID = voiceID; self.score = score; self.automatic = automatic
    }
}

/// Assigns saved voices to a note's speakers: each voice and each speaker at most once, best score first.
public enum VoiceMatcher {
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        return vector.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, let x = normalized(a), let y = normalized(b) else { return nil }
        return zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The best saved voice for each print with enough speech. Only samples of the print's model count. `excluded`
    /// lists, per speaker, the voices the user said it is not ("Not Luca"): those pairs are removed before the
    /// assignment and before the rival check. A match is automatic only when no other voice for this speaker and no
    /// other speaker for this voice comes within `margin`.
    public static func match(prints: [SpeakerPrint], voices: [SavedVoice], excluded: [String: Set<UUID>] = [:],
                             thresholds: VoiceThresholds = .ios) -> [String: VoiceMatch] {
        var scores: [(speaker: String, voice: UUID, score: Float)] = []
        for print in prints where print.speechSeconds >= VoiceLibrary.minimumRememberSeconds {
            for voice in voices where !(excluded[print.speakerID]?.contains(voice.id) ?? false) {
                if let score = voice.score(print) { scores.append((print.speakerID, voice.id, score)) }
            }
        }
        scores.sort {
            $0.score == $1.score ? ($0.speaker, $0.voice.uuidString) < ($1.speaker, $1.voice.uuidString) : $0.score > $1.score
        }
        var assigned: [String: VoiceMatch] = [:]
        var taken: Set<UUID> = []
        for (speaker, voice, score) in scores where score >= thresholds.suggest {
            guard assigned[speaker] == nil, !taken.contains(voice) else { continue }
            let rival = scores.filter { ($0.speaker == speaker) != ($0.voice == voice) }.map(\.score).max()
            let automatic = score >= thresholds.automatic && rival.map { score - $0 >= thresholds.margin } ?? true
            assigned[speaker] = VoiceMatch(voiceID: voice, score: score, automatic: automatic)
            taken.insert(voice)
        }
        return assigned
    }
}
