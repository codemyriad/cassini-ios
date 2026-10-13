import Foundation

/** The portable document is authoritative; Transcript is only a selected viewer projection. */
public struct CassiniDocument: Equatable, Sendable {
    public var state: DocumentState
    public var manifest: JSONObject?
    public var variants: [Variant]
    /** The OpusTags comments that decode as UTF-8, in file order. */
    public var comments: [String]
    /** Foreign comments that are not UTF-8. They are never interpreted, only carried into a rewritten file. */
    public var opaqueComments: [[UInt8]]
    /** What did not decide [state]: a code, or `code: TAG` when one tag is at fault. */
    public var warnings: [String]

    public init(state: DocumentState, manifest: JSONObject? = nil, variants: [Variant] = [], comments: [String] = [],
                opaqueComments: [[UInt8]] = [], warnings: [String] = []) {
        self.state = state; self.manifest = manifest; self.variants = variants
        self.comments = comments; self.opaqueComments = opaqueComments; self.warnings = warnings
    }

    public struct Variant: Equatable, Sendable {
        public let id: String, descriptor: JSONObject, body: String?, transcript: Transcript?
        public var error: String?
    }

    public var defaultId: String? { (variants.first { $0.descriptor["default"] == .bool(true) } ?? variants.first)?.id }
    public var title: String { manifest?["meeting"]?.object?["title"]?.string ?? "" }
    public func selected(_ id: String? = nil) -> Variant? {
        let wanted = id ?? defaultId
        return variants.first { $0.id == wanted }
    }
    public func speakerLabel(_ id: String) -> String? {
        guard let speakers = manifest?["speakers"]?.array else { return nil }
        for s in speakers where sameBytes(s.object?["id"]?.string, id) { return s.object?["label"]?.string ?? "" }
        return nil
    }

    public static let format = "org.cassini.portable-meeting/1"
    public static let vendor = "cassini-ios/0.1"
    static let schema = "https://format.gocassini.com/schema/cassini-portable-meeting-manifest-v1.schema.json"
    static let matchPolicy = "exact-opus-audio-v1"
    static let manifestPrefix = "CASSINI_PAYLOAD_"
    static let integrityKeys: Set<String> = ["matchPolicy", "opusAudioSha256", "sampleRate", "channels", "sampleCount", "durationMs"]
    static let refKeys: Set<String> = ["prefix", "mime", "encoding", "chunkCount", "sha256", "rawBytes", "gzipBytes"]
    static let fields: [(key: String, suffix: String)] = [("mime", "MIME"), ("encoding", "ENCODING"), ("chunkCount", "CHUNK_COUNT"),
                                                                  ("sha256", "SHA256"), ("rawBytes", "RAW_BYTES"), ("gzipBytes", "GZIP_BYTES")]
    static let decodeHint = "Concatenate CASSINI_PAYLOAD_000..N for the manifest; for a transcript body concatenate " +
        "CASSINI_TX_<ID>_PAYLOAD_000..N. Each chunk set: base64url decode, gzip decompress, parse UTF-8 JSON."
    /** The `CASSINI_AUDIO_*` tags and the `integrity` member each one copies. */
    static let audioMirrors: [(suffix: String, field: String)] = [
        ("SAMPLE_RATE", "sampleRate"), ("CHANNELS", "channels"), ("SAMPLE_COUNT", "sampleCount"), ("DURATION_MS", "durationMs"),
        ("MATCH_POLICY", "matchPolicy"), ("OPUS_SHA256", "opusAudioSha256"),
    ]
    /** The optional origin tags and the `meeting` member each one copies; written only when the member is there. */
    static let meetingMirrors: [(tag: String, field: String)] = [
        ("CASSINI_ROOM_ID", "roomId"), ("CASSINI_JOB_ID", "jobId"), ("CASSINI_ATTEMPT_NUMBER", "attemptNumber"),
        ("CASSINI_PROCESSED_AT", "processedAtUtc"), ("CASSINI_RECORDED_AT_LOCAL", "recordedAtLocal"),
    ]
    /**
     * The non-chunk tags every write derives from the manifest it embeds. A source's own spelling of them may be
     * stale (SPEC.md "When a tag and the manifest disagree"), so a writer drops it rather than carrying it forward.
     */
    static let derivedNames: Set<[UInt8]> = Set(([
        "CASSINI_FORMAT", "CASSINI_PROFILE", "CASSINI_PAYLOAD_SCHEMA", "CASSINI_TRANSCRIPT_IDS", "CASSINI_TRANSCRIPT_DEFAULT",
        "CASSINI_DECODE_HINT", "CASSINI_SPEAKER_COUNT", "CASSINI_MEETING_ID", "CASSINI_CREATED_AT",
    ] + audioMirrors.map { "CASSINI_AUDIO_\($0.suffix)" } + meetingMirrors.map { $0.tag }).map { Array($0.utf8) })

    /** The name of a comment, ASCII upper case: the bytes before the first `=`. */
    static func tagName(_ comment: String) -> String { tagName(Array(comment.utf8)) }
    static func tagName(_ comment: [UInt8]) -> String { asciiUppercased(comment.prefix { $0 != UInt8(ascii: "=") }) }
}
