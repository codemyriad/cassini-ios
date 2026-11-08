import Foundation

/// C API output. Validation happens before any word can be published by an eventual production pipeline adapter.
public struct WhistleResult: Decodable, Equatable, Sendable {
    public struct Word: Decodable, Equatable, Sendable {
        public var word: String
        public var start: Double
        public var end: Double
        public var probability: Double
    }
    public var text: String
    public var language: String
    public var words: [Word]

    private enum CodingKeys: String, CodingKey { case text, language, words }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        text = try fields.decode(String.self, forKey: .text)
        language = try fields.decode(String.self, forKey: .language)
        if text.isEmpty { words = try fields.decodeIfPresent([Word].self, forKey: .words) ?? [] }
        else { words = try fields.decode([Word].self, forKey: .words) }
    }

    public static func parse(_ data: Data, samples: Int) throws -> Self {
        guard samples > 0, samples <= 240_128, data.count <= 1_048_576 else { throw WhistleError.invalidInput }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.language.utf8.count <= 64, result.words.count <= 16_000 else { throw WhistleError.invalidOutput }
        var previous = 0.0
        let duration = Double(samples) / 16_000
        for word in result.words {
            guard !word.word.isEmpty, word.start.isFinite, word.end.isFinite, word.probability.isFinite,
                  word.start >= previous, word.end >= word.start, word.end <= duration + 0.08,
                  (0...1).contains(word.probability) else { throw WhistleError.invalidOutput }
            previous = word.start
        }
        return result
    }
}

public enum WhistleError: Error, Equatable, Sendable {
    case unavailable, integrity, privacy, missingAPI, invalidInput, invalidOutput, nativeFailure
    /// Apple-processed images need separate acceptance; never silently skip their integrity check.
    case encryptedRuntime
}

/// Testable admission boundary. Even an existing runtime is not entered with missing or changed flags.
public enum WhistlePrivacy {
    public static let required = ["NEEDLE_TELEMETRY": "0", "DO_NOT_TRACK": "1", "ORT_DISABLE_TELEMETRY": "1"]

    public static func enter<T>(environment: [String: String], _ load: () throws -> T) throws -> T {
        guard required.allSatisfy({ environment[$0.key] == $0.value }) else { throw WhistleError.privacy }
        return try load()
    }
}
