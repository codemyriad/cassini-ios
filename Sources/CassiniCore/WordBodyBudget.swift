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
 * more for real speech, so a file holds at most two full-length variants and possibly only one, and an imported file's
 * own tags take their share. Check [fitsHeader] once the words are final, before the seal.
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
     * The OpusTags bytes of [existing]'s comments plus [transcript]'s encoded chunk set: what a seal beside a verified
     * document writes, less the growth of its manifest. Stale copies that the seal replaces are counted too, so this
     * errs high. It compresses the whole body, so call it once when the words are final, not per window.
     */
    public static func headerBytes(adding transcript: Transcript, to existing: CassiniDocument) throws -> Int64 {
        try headerBytes(adding: transcript, keeping: CassiniDocument.tagsPacket(existing.comments, opaque: existing.opaqueComments))
    }

    /**
     * As [headerBytes(adding:to:)] for a fresh seal of [source], which keeps every foreign comment of the audio: an
     * imported file's cover art or lyrics count against the same limit. What the seal carries from [carried]'s manifest
     * (`CassiniDocument.carriedMembers`, such as a long notes list under `x`, and its kept `meeting` and `provenance`
     * members) grows the manifest by about its own encoded size, so that is counted too.
     */
    public static func headerBytes(adding transcript: Transcript, sealing source: ByteSource,
                                   carrying carried: CassiniDocument? = nil) throws -> Int64 {
        try headerBytes(adding: transcript, sealing: source, carried: carriedText(of: carried))
    }

    /** Whether sealing [transcript] beside [existing] keeps the header within [maxHeaderBytes]. */
    public static func fitsHeader(_ transcript: Transcript, beside existing: CassiniDocument) throws -> Bool {
        try headerBytes(adding: transcript, to: existing) <= maxHeaderBytes
    }

    /** The manifest bytes, uncompressed, that what a fresh seal carries may fill: the payload limit less room for the rest. */
    public static let maxCarriedBytes = Int64(CassiniPayload.maxRaw) - (256 << 10)

    /**
     * Whether a fresh seal of [transcript] into [source], carrying [carried]'s private and unknown manifest members,
     * keeps the header within [maxHeaderBytes] and the manifest within the payload limit: private data that gzip
     * shrinks well can fit the header and still make a manifest the codec refuses.
     */
    public static func fitsHeader(_ transcript: Transcript, sealing source: ByteSource,
                                  carrying carried: CassiniDocument? = nil) throws -> Bool {
        let text = carriedText(of: carried)
        guard Int64(text?.utf8.count ?? 0) <= maxCarriedBytes else { return false }
        return try headerBytes(adding: transcript, sealing: source, carried: text) <= maxHeaderBytes
    }

    private static func headerBytes(adding transcript: Transcript, sealing source: ByteSource, carried: String?) throws -> Int64 {
        let foreign = try CassiniDocument.foreignComments(OggOpus.headers(source).tags)
        let kept = try headerBytes(adding: transcript, keeping: CassiniDocument.tagsPacket(foreign.text, opaque: foreign.opaque))
        return try kept + carriedBytes(carried)
    }

    /** What a fresh seal carries from [source]'s manifest, as one compact JSON object; nil when it carries nothing. */
    private static func carriedText(of source: CassiniDocument?) -> String? {
        var members = CassiniDocument.carriedMembers(of: source).map { ($0.key, $0.value) }
        if let meeting = CassiniDocument.carriedMeeting(of: source) { members.append(("meeting", .object(meeting))) }
        let provenance = CassiniDocument.carriedProvenance(of: source)
        if !provenance.isEmpty { members.append(("provenance", .object(JSONObject(provenance.map { ($0.key, $0.value) })))) }
        return members.isEmpty ? nil : JSONObject(members).serialized()
    }

    /**
     * The manifest chunk tags that [text] alone would encode to (gzip, unpadded base64url, 4096 characters a chunk,
     * each behind its name and length): about what it adds to a manifest. Counted, not encoded, so a large `x` is
     * compressed once and never parsed again.
     */
    private static func carriedBytes(_ text: String?) throws -> Int64 {
        guard let text else { return 0 }
        let gzipped = Int64(try CassiniPayload.gzip(Array(text.utf8)).count)
        let encoded = (gzipped * 4 + 2) / 3
        let chunks = (encoded + 4095) / 4096
        return encoded + chunks * Int64(CassiniDocument.manifestPrefix.utf8.count + 4 + 1 + 4)
    }

    private static func headerBytes(adding transcript: Transcript, keeping kept: [UInt8]) throws -> Int64 {
        let body = try CassiniPayload.encode(prefix: "CASSINI_TX_WORDS_00000000_PAYLOAD_", mime: CassiniPayload.wordMime, text: transcript.json())
        return Int64(kept.count) + body.tags.reduce(0) { $0 + Int64($1.utf8.count) + 4 }
    }
}
