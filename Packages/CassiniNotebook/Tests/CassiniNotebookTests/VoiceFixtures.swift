import Foundation
@testable import CassiniNotebook

/// Voices and prints for the speaker tests: unit vectors in a small space, of the model "m" unless said otherwise.
enum VoiceFixtures {
    static let model = "m"
    static let dimension = 8

    static func axis(_ index: Int, dimension: Int = dimension) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[index] = 1
        return vector
    }

    /// A unit vector at cosine `score` from axis 0, leaning toward axis `other`.
    static func near(_ score: Float, _ other: Int = 1, dimension: Int = dimension) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[0] = score
        vector[other] = (1 - score * score).squareRoot()
        return vector
    }

    /// A stable id from a short name, so tests read like Android's ("anna", "luca").
    static func id(_ name: String) -> UUID {
        let hex = name.utf8.map { String(format: "%02x", $0) }.joined()
        let padded = (hex + String(repeating: "0", count: 32)).prefix(32)
        let chars = Array(padded)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
        return UUID(uuidString: groups.joined(separator: "-"))!
    }

    static func print(_ speaker: String = "s", _ vector: [Float], seconds: Double = 12, model: String = model) -> SpeakerPrint {
        SpeakerPrint(speakerID: speaker, model: model, vector: vector, speechSeconds: seconds)
    }

    static func print(_ vector: [Float]) -> SpeakerPrint { print("s", vector) }

    /// A saved voice with one sample.
    static func voice(_ key: String, _ name: String? = nil, _ vector: [Float] = axis(0), seconds: Double = 30,
                      model: String = model, note: UUID = UUID()) -> SavedVoice {
        SavedVoice(id: id(key), name: name ?? key,
                   samples: [VoiceSample(noteID: note, print: print("src-\(key)", vector, seconds: seconds, model: model))])
    }
}
