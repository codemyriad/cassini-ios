import Foundation

/// When a match names a speaker automatically, when it is only offered, and how far ahead of a rival it must be.
public struct VoiceThresholds: Hashable, Sendable {
    public var automatic: Float
    public var suggest: Float
    public var margin: Float
    public init(automatic: Float, suggest: Float, margin: Float) {
        self.automatic = automatic; self.suggest = suggest; self.margin = margin
    }

    /// Android's values for CAM++ (`Voiceprints.THRESHOLDS`), measured with its VoiceprintCalibrationTest: the same
    /// person in different recordings scores 0.40–0.87 (median 0.72), different people −0.04–0.70 (median 0.37), and a
    /// stranger still reaches 0.70, so automatic naming stays above that; a suggestion sits under the lowest right
    /// identification (0.52).
    public static let campplus = VoiceThresholds(automatic: 0.72, suggest: 0.50, margin: 0.08)
}

/// The voiceprint model every print and saved voice sample names: CAM++ (`3dspeaker_speech_campplus_sv_en_voxceleb_16k`,
/// `ModelCatalog.voiceprintModel`), identified by the SHA-256 of its file as Android's `JobProvenance.PRINT_MODEL`, so
/// prints of both apps are of one model. A print has `dimension` values.
public enum VoiceprintModel {
    public static let name = "3dspeaker_speech_campplus_sv_en_voxceleb_16k"
    public static let sha256 = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"
    public static let dimension = 512
    public static let thresholds = VoiceThresholds.campplus
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
                             thresholds: VoiceThresholds = .campplus) -> [String: VoiceMatch] {
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
