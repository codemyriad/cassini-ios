/**
 * The size of the word body that the seal writes (`Transcript.json`, compact JSON), counted without writing it. The
 * payload codec refuses a body over [CassiniPayload.maxRaw] (16 MiB), so this is the real length limit of one
 * transcript: about 150,000 words with diarization speaker ids, or some 16 hours of continuous speech. A job can count
 * the words after each window and stop as soon as they pass [maxBytes], not after hours of work at the seal.
 *
 * [bytes] is an upper bound of the body length: it counts every control character as a `\uXXXX` escape and a comma
 * after every item.
 */
public enum WordBodyBudget {
    /** The body bytes that a transcript may have: the format limit less a margin of 256 KiB. */
    public static let maxBytes = Int64(CassiniPayload.maxRaw) - (256 << 10)

    /** The bytes of one item without its four values: `{"speaker":"","startMs":,"endMs":,"text":""}` and a comma. */
    static let itemBytes: Int64 = 45

    /** The body without items: the braces, `format`, `wordCount`, `items` and room for the digits. */
    private static let headerBytes: Int64 = 128

    /** The bytes of `,"language":""` around the language value. */
    private static let languageBytes: Int64 = 14

    /** The length of `Transcript(words, language: language).json()`, as an upper bound. */
    public static func bytes(_ words: [Word], language: String = "") -> Int64 {
        var total = headerBytes + (language.isEmpty ? 0 : languageBytes + quoted(language))
        for word in words {
            total += itemBytes + quoted(word.speaker) + digits(word.startMs) + digits(word.endMs) + quoted(word.text)
        }
        return total
    }

    /** Whether the body of [words] fits in [maxBytes]. */
    public static func fits(_ words: [Word], language: String = "") -> Bool { bytes(words, language: language) <= maxBytes }

    private static func digits(_ value: Int64) -> Int64 { Int64(String(value).utf8.count) }

    /** The UTF-8 bytes of [text] inside a JSON string, escapes included. */
    private static func quoted(_ text: String) -> Int64 {
        var bytes: Int64 = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C: bytes += 2
            case ..<0x20: bytes += 6
            default: bytes += Int64(UTF8.width(scalar))
            }
        }
        return bytes
    }
}
