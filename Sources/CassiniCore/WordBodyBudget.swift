/**
 * The size of the word body that the seal writes (`Transcript.json`, compact JSON), counted without writing it. The
 * payload codec refuses a body over [CassiniPayload.maxRaw] (16 MiB), so this is the real length limit of one
 * transcript: about 150,000 words with diarization speaker ids, or some 16 hours of continuous speech. A job can count
 * the words after each window and stop as soon as they pass [maxBytes], not after hours of work at the seal.
 *
 * [bytes] is an upper bound of the body length: it counts every control character as a `\uXXXX` escape and a comma
 * after every item.
 *
 * The body limit is per transcript, but every variant and the manifest share one OpusTags packet of at most
 * [OggOpus.maxHeaderBytes] (8 MiB). A body at the budget encodes to roughly a third of that for repetitive text and
 * more for real speech, so a file holds at most two full-length variants and possibly only one. Before adding a
 * variant to an existing document, check [fitsHeader] once the words are final.
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

    /** The OpusTags bytes a seal may fill: the reader's limit less room for the grown manifest. */
    public static let maxHeaderBytes = Int64(OggOpus.maxHeaderBytes) - (256 << 10)

    /**
     * The OpusTags bytes of [existing]'s comments (none for a fresh seal) plus [transcript]'s encoded chunk set.
     * This compresses the whole body, so call it once when the words are final, not per window.
     */
    public static func headerBytes(adding transcript: Transcript, to existing: CassiniDocument?) throws -> Int64 {
        let kept = existing.map { CassiniDocument.tagsPacket($0.comments, opaque: $0.opaqueComments).count } ?? 0
        let body = try CassiniPayload.encode(prefix: "CASSINI_TX_WORDS_00000000_PAYLOAD_", mime: CassiniPayload.wordMime, text: transcript.json())
        return Int64(kept) + body.tags.reduce(0) { $0 + Int64($1.utf8.count) + 4 }
    }

    /** Whether sealing [transcript] beside [existing] keeps the header within [maxHeaderBytes]. */
    public static func fitsHeader(_ transcript: Transcript, beside existing: CassiniDocument?) throws -> Bool {
        try headerBytes(adding: transcript, to: existing) <= maxHeaderBytes
    }
}
