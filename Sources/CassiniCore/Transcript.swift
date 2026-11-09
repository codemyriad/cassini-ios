import Foundation

public struct Word: Hashable, Sendable {
    public let speaker: String, startMs: Int64, endMs: Int64, text: String
    public let lowConfidenceSpeaker: Bool
    public init(_ speaker: String, _ startMs: Int64, _ endMs: Int64, _ text: String, lowConfidenceSpeaker: Bool = false) {
        self.speaker = speaker; self.startMs = startMs; self.endMs = endMs; self.text = text
        self.lowConfidenceSpeaker = lowConfidenceSpeaker
    }
}

/**
 * Decode scaffolding, never transcript data: [capMs] is the furthest end the word gate may extend
 * the word to over its speaker's continuing audio, the end of its last piece INCLUDING trailing
 * punctuation. A cap not above the word's end permits no extension. Android's `TimedWord`; iOS names it
 * `DecodedWord` because the note model already has a `TimedWord`.
 */
public struct DecodedWord: Hashable, Sendable {
    public var word: Word
    public var capMs: Int64
    public init(_ word: Word, capMs: Int64 = 0) { self.word = word; self.capMs = capMs }
    public var extentCapMs: Int64 { capMs > word.endMs ? capMs : word.endMs }
}

/**
 * Word order is canonical; never sort a Cassini transcript by time. [language] is empty unless something identified
 * it: the format reads an absent language as "nobody said", never as a default.
 */
public struct Transcript: Hashable, Sendable {
    public static let format = "cassini.words.v1"

    public var words: [Word]
    public var language: String
    public init(_ words: [Word], language: String = "") { self.words = words; self.language = language }

    /** The word body as the seal writes it: compact JSON, with `language` only when it is known. */
    public func json() -> String {
        var body = JSONObject([("format", .string(Self.format))])
        if !language.isEmpty { body["language"] = .string(language) }
        body["wordCount"] = .int(words.count)
        body["items"] = .array(words.map { w in
            var item = JSONObject([("speaker", .string(w.speaker)), ("startMs", .int(w.startMs)),
                                   ("endMs", .int(w.endMs)), ("text", .string(w.text))])
            if w.lowConfidenceSpeaker { item["lowConfidenceSpeaker"] = .bool(true) }
            return .object(item)
        })
        return body.serialized()
    }

    public static func fromJSON(_ json: String) throws -> Transcript {
        let body = try JSON.parseObject(json)
        try check(body["format"] == .string(format), "Unsupported transcript format")
        let items: [JSON]
        switch body["items"] {
        case nil, .null?: items = []
        case .array(let a)?: items = a
        default: throw CassiniError("Transcript items are not an array")
        }
        let words = try items.map { item -> Word in
            guard let o = item.object, let speaker = o["speaker"]?.string, let text = o["text"]?.string else {
                throw CassiniError("Malformed transcript word")
            }
            let word = Word(speaker, try o.number("startMs"), try o.number("endMs"), text,
                            lowConfidenceSpeaker: o["lowConfidenceSpeaker"]?.bool == true)
            try check(word.endMs >= word.startMs && !word.speaker.isEmpty && !text.isEmpty &&
                      !text.contains { $0.isWhitespace }, "Invalid word timings")
            return word
        }
        return Transcript(words, language: body["language"]?.string ?? "")
    }

    /** SentencePiece pieces carry seconds, including TDT durations. No guessed alignment. */
    public static func fromTokens(_ tokens: [String], timestamps: [Float], durations: [Float]) throws -> Transcript {
        Transcript(try timedWordsFromTokens(tokens, timestamps: timestamps, durations: durations).map { $0.word })
    }

    /**
     * [fromTokens] words with their extension cap: the end of the word's last piece, punctuation
     * included. Only a word with a speech-bearing piece gets one; a mark alone has no audio of its
     * own, and its timestamp is the next onset, so a cap would walk it over the next word.
     */
    public static func timedWordsFromTokens(_ tokens: [String], timestamps: [Float], durations: [Float]) throws -> [DecodedWord] {
        try check(tokens.count == timestamps.count && tokens.count == durations.count, "Invalid word timings")
        var words: [DecodedWord] = []
        var text = ""
        var start: Int64 = 0, speechEnd: Int64 = 0, pieceEnd: Int64 = 0
        var spoken = false
        var previousTimestamp: Float = -1
        func flush() {
            let end = max(start, speechEnd)
            if !text.isEmpty { words.append(DecodedWord(Word("spk_1", start, end, text), capMs: spoken ? max(end, pieceEnd) : end)) }
            text = ""
            spoken = false
        }
        for (i, original) in tokens.enumerated() {
            let timestamp = timestamps[i], duration = durations[i]
            try check(timestamp.isFinite && duration.isFinite && timestamp >= 0 && duration >= 0, "Invalid word timings")
            try check(timestamp >= previousTimestamp, "Invalid word timings")
            previousTimestamp = timestamp
            let boundary = original.hasPrefix("▁") || original.hasPrefix(" ") || original == "<space>"
            if boundary { flush() }
            let piece = original == "<space>" ? "" :
                (original.hasPrefix("▁") ? String(original.dropFirst()) : original).trimmingCharacters(in: .whitespacesAndNewlines)
            try check(!piece.contains { $0.isWhitespace || $0 == "▁" }, "Invalid word timings")
            if !piece.isEmpty {
                if text.isEmpty {
                    start = Int64((Double(timestamp) * 1000).rounded())
                    speechEnd = start
                    pieceEnd = start
                }
                text += piece
                let end = Int64(((Double(timestamp) + Double(duration)) * 1000).rounded())
                pieceEnd = max(pieceEnd, end)
                // Punctuation can be stamped at the NEXT acoustic onset. Preserve its text,
                // but do not stretch the previous word across the intervening silence.
                if piece.unicodeScalars.contains(where: isLetterOrDigit) {
                    spoken = true
                    speechEnd = max(speechEnd, end)
                }
            }
        }
        flush()
        return words
    }

    /// Android's `Char.isLetterOrDigit`: a letter (category L) or a decimal digit (Nd), so a lone "²", "½" or "Ⅻ" is
    /// not speech. Swift's `Character.isNumber` would count it.
    static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }
}
