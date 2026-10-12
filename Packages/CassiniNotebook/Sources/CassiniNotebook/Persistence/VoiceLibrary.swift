import Foundation

public struct SpeakerPrint: Codable, Hashable, Sendable {
    public var speakerID: String
    public var model: String
    public var vector: [Float]
    public var speechSeconds: Double
    public init(speakerID: String, model: String, vector: [Float], speechSeconds: Double) {
        self.speakerID = speakerID; self.model = model; self.vector = vector; self.speechSeconds = speechSeconds
    }
}
public struct VoiceSample: Codable, Hashable, Sendable {
    public var noteID: UUID
    public var print: SpeakerPrint
    public init(noteID: UUID, print: SpeakerPrint) { self.noteID = noteID; self.print = print }
}
public struct SavedVoice: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var samples: [VoiceSample]
    public init(name: String, samples: [VoiceSample]) { self.name = name; self.samples = samples }
}
public struct VoiceMatch: Equatable, Sendable {
    public var voiceID: UUID
    public var score: Float
    public var automatic: Bool
}
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
    /// One-to-one assignment with a rival margin, matching Android's assignment rules.
    /// Thresholds are deliberately conservative for the iOS embedding model; never reuse CAM++ thresholds.
    public static func match(prints: [SpeakerPrint], voices: [SavedVoice], excluded: [String: Set<UUID>] = [:], automatic: Float = 0.85, suggest: Float = 0.65, margin: Float = 0.12) -> [String: VoiceMatch] {
        var scores: [(String, UUID, Float)] = []
        for print in prints where print.speechSeconds >= 6 {
            for voice in voices where !(excluded[print.speakerID]?.contains(voice.id) ?? false) {
                let samples = voice.samples.filter { $0.print.model == print.model && $0.print.vector.count == print.vector.count && $0.print.speechSeconds >= 6 }.compactMap { normalized($0.print.vector) }
                guard !samples.isEmpty else { continue }
                let mean = samples.reduce([Float](repeating: 0, count: print.vector.count)) { sum, v in zip(sum, v).map(+) }
                if let score = cosine(print.vector, mean) { scores.append((print.speakerID, voice.id, score)) }
            }
        }
        scores.sort { $0.2 == $1.2 ? ($0.0 + $0.1.uuidString) < ($1.0 + $1.1.uuidString) : $0.2 > $1.2 }
        var assigned: [String: VoiceMatch] = [:]; var taken: Set<UUID> = []
        for (speaker, voice, score) in scores where score >= suggest {
            guard assigned[speaker] == nil, !taken.contains(voice) else { continue }
            let rival = scores.filter { ($0.0 == speaker) != ($0.1 == voice) }.map(\.2).max()
            assigned[speaker] = VoiceMatch(voiceID: voice, score: score, automatic: score >= automatic && (rival == nil || score - rival! >= margin))
            taken.insert(voice)
        }
        return assigned
    }
}

/// Private voice material lives separately from note metadata so JSON/audio exports cannot include it.
public final class VoiceLibrary {
    private let root: URL
    public private(set) var voices: [SavedVoice]
    public init(root: URL) throws {
        self.root = root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var resource = self.root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
        let file = self.root.appendingPathComponent("voices.json")
        voices = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([SavedVoice].self, from: Data(contentsOf: file)) : []
    }
    public func save(_ values: [SavedVoice]) throws {
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("voices.json"), options: .atomic)
        voices = values
    }
    public func prints(noteID: UUID) throws -> [SpeakerPrint] {
        let url = root.appendingPathComponent(noteID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SpeakerPrint].self, from: Data(contentsOf: url))
    }
    public func savePrints(_ prints: [SpeakerPrint], noteID: UUID) throws {
        try JSONEncoder().encode(prints).write(to: root.appendingPathComponent(noteID.uuidString + ".json"), options: .atomic)
    }
    public var hasEvidence: Bool {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).contains { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }
    public func forgetAll() throws {
        try save([])
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            try FileManager.default.removeItem(at: url)
        }
    }
    public func removeEvidence(noteID: UUID) throws {
        var copy = voices
        for index in copy.indices { copy[index].samples.removeAll { $0.noteID == noteID } }
        try save(copy)
        let url = root.appendingPathComponent(noteID.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
