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
        for s in speakers where s.object?["id"]?.string == id { return s.object?["label"]?.string ?? "" }
        return nil
    }

    public static let format = "org.cassini.portable-meeting/1"
    public static let vendor = "cassini-ios/0.1"
    static let schema = "https://format.gocassini.com/schema/cassini-portable-meeting-manifest-v1.schema.json"
    static let matchPolicy = "exact-opus-audio-v1"
    private static let manifestPrefix = "CASSINI_PAYLOAD_"
    private static let integrityKeys: Set<String> = ["matchPolicy", "opusAudioSha256", "sampleRate", "channels", "sampleCount", "durationMs"]
    private static let refKeys: Set<String> = ["prefix", "mime", "encoding", "chunkCount", "sha256", "rawBytes", "gzipBytes"]
    private static let fields: [(key: String, suffix: String)] = [("mime", "MIME"), ("encoding", "ENCODING"), ("chunkCount", "CHUNK_COUNT"),
                                                                  ("sha256", "SHA256"), ("rawBytes", "RAW_BYTES"), ("gzipBytes", "GZIP_BYTES")]
    /** The copies a new seal writes afresh; every other CASSINI_ tag of a verified source is kept. */
    private static let resealed: Set<String> = [
        "CASSINI_FORMAT", "CASSINI_PROFILE", "CASSINI_PAYLOAD_SCHEMA", "CASSINI_TRANSCRIPT_IDS", "CASSINI_TRANSCRIPT_DEFAULT",
        "CASSINI_DECODE_HINT", "CASSINI_SPEAKER_COUNT", "CASSINI_MEETING_ID", "CASSINI_CREATED_AT", "CASSINI_AUDIO_SAMPLE_RATE",
        "CASSINI_AUDIO_CHANNELS", "CASSINI_AUDIO_SAMPLE_COUNT", "CASSINI_AUDIO_DURATION_MS", "CASSINI_AUDIO_MATCH_POLICY",
        "CASSINI_AUDIO_OPUS_SHA256",
    ]

    /** The name of a comment, ASCII upper case: the bytes before the first `=`. */
    static func tagName(_ comment: String) -> String { tagName(Array(comment.utf8)) }
    static func tagName(_ comment: [UInt8]) -> String { asciiUppercased(comment.prefix { $0 != UInt8(ascii: "=") }) }

    // MARK: Reading

    public static func read(_ bytes: [UInt8]) -> CassiniDocument { read(verify: true, reportsIOErrors: false) { ArraySource(bytes) } }
    /** Streams [url]; without [verify] only the headers are read and the audio stays unverified. */
    public static func read(_ url: URL, verify: Bool = true) -> CassiniDocument {
        read(verify: verify, reportsIOErrors: false) { try FileSource(url) }
    }

    /** [reportsIOErrors] makes a file that cannot be opened or read [DocumentState.unreadable] instead of plain audio. */
    static func read(verify: Bool, reportsIOErrors: Bool, open: () throws -> ByteSource) -> CassiniDocument {
        // Audio corruption must not conceal an otherwise intact manifest/transcript.
        let head: [UInt8], tagPacket: [UInt8]
        do {
            (head, tagPacket) = try OggOpus.headers(open())
        } catch let error as OggOpus.HeaderTooLarge {
            return CassiniDocument(state: .invalidMetadata, warnings: [error.description])
        } catch is CassiniError {
            return CassiniDocument(state: .plainAudio)
        } catch {
            guard reportsIOErrors else { return CassiniDocument(state: .plainAudio) }
            return CassiniDocument(state: .unreadable, warnings: [error.localizedDescription])
        }
        let parsed: TagComments
        do {
            parsed = try TagComments(packet: tagPacket)
        } catch {
            return CassiniDocument(state: .invalidMetadata, warnings: ["\(error)"])
        }
        var document = CassiniDocument(state: .plainAudio, comments: parsed.text, opaqueComments: parsed.opaque, warnings: parsed.warnings)
        var tags: [String: String] = [:]
        var duplicates: [String] = []
        for comment in parsed.text {
            let utf8 = comment.utf8
            guard let equals = utf8.firstIndex(of: UInt8(ascii: "=")), equals != utf8.startIndex else { continue }
            let name = asciiUppercased(utf8[..<equals])
            let value = String(decoding: utf8[utf8.index(after: equals)...], as: UTF8.self)
            if tags.updateValue(value, forKey: name) != nil &&
                (name == "CASSINI_FORMAT" || name.hasPrefix(manifestPrefix) || name.hasPrefix("CASSINI_TX_")) { duplicates.append(name) }
        }
        guard let format = tags["CASSINI_FORMAT"] else { return document }
        if !duplicates.isEmpty {
            document.state = .invalidMetadata
            document.warnings += duplicates.map { "duplicate-tag: \($0)" }
            return document
        }
        guard sameBytes(format, self.format) else {
            document.state = .unknownFormat
            return document
        }
        let manifest: JSONObject
        do {
            try check(sameBytes(tags["CASSINI_PROFILE"], "ogg-opus") && sameBytes(tags["CASSINI_PAYLOAD_MIME"], CassiniPayload.mime), "Unsupported profile")
            try check(sameBytes(tags["CASSINI_PAYLOAD_SCHEMA"], schema), "Unsupported schema")
            manifest = try JSON.parseObject(payload(tags, manifestRef(tags)))
            try validateManifest(manifest)
        } catch {
            document.state = .invalidMetadata
            document.warnings.append("\(error)")
            return document
        }
        var warnings = document.warnings
        let descriptors = (try? manifest.array("transcripts")) ?? []
        let variants: [Variant] = descriptors.compactMap { $0.object }.map { descriptor in
            let id = descriptor["id"]?.string ?? ""
            let ref = descriptor["payloadRef"]?.object ?? JSONObject()
            let prefix = asciiUppercased(ref["prefix"]?.string ?? "")
            for (field, suffix) in fields where !sameBytes(tags[prefix + suffix], ref[field]?.text) {
                warnings.append("tag-manifest-disagreement: \(prefix)\(suffix)")
            }
            do {
                // The format names the body; the media type is only a hint.
                try check(ref.hasExactly(refKeys) && descriptor["format"] == .string(Transcript.format), "unsupported-transcript-format")
                if ref["mime"] != .string(CassiniPayload.wordMime) { warnings.append("transcript-mime-mismatch: \(id)") }
                let body = try payload(tags, ref)
                return Variant(id: id, descriptor: descriptor, body: body, transcript: try Transcript.fromJSON(body))
            } catch {
                return Variant(id: id, descriptor: descriptor, body: nil, transcript: nil, error: "\(error)")
            }
        }
        let defaultVariant = (variants.first { $0.descriptor["default"] == .bool(true) } ?? variants[0]).id
        if !sameBytes(tags["CASSINI_TRANSCRIPT_IDS"], variants.map { $0.id }.sorted().joined(separator: ",")) {
            warnings.append("tag-manifest-disagreement: CASSINI_TRANSCRIPT_IDS")
        }
        if !sameBytes(tags["CASSINI_TRANSCRIPT_DEFAULT"], defaultVariant) { warnings.append("tag-manifest-disagreement: CASSINI_TRANSCRIPT_DEFAULT") }
        let integrity = (try? manifest.object("integrity")) ?? JSONObject()
        let audio = (try? manifest.object("audio")) ?? JSONObject()
        let mirrors = [("SAMPLE_RATE", "sampleRate"), ("CHANNELS", "channels"), ("SAMPLE_COUNT", "sampleCount"),
                       ("DURATION_MS", "durationMs"), ("MATCH_POLICY", "matchPolicy"), ("OPUS_SHA256", "opusAudioSha256")]
        for (suffix, field) in mirrors where !sameBytes(tags["CASSINI_AUDIO_\(suffix)"], integrity[field]?.text) {
            warnings.append("tag-manifest-disagreement: CASSINI_AUDIO_\(suffix)")
        }
        // The manifest is the record and other copies only warn, but audio cannot be verified against two
        // different digest claims.
        let digestClaimsAgree = sameBytes(tags["CASSINI_AUDIO_OPUS_SHA256"], integrity["opusAudioSha256"]?.string)
        var state = DocumentState.unverified
        if verify && digestClaimsAgree && integrity.hasExactly(integrityKeys) && integrity["matchPolicy"] == .string(matchPolicy) {
            do {
                let stream = try OggOpus.scan(open())
                try check(stream.head == head, "OpusHead changed")
                let digest = try stream.digest()
                let shared = ["sampleRate", "channels", "sampleCount", "durationMs"]
                let shapeMatches = try audio.number("sampleRate") == 48000 && audio.number("channels") == Int64(stream.channels) &&
                    audio.number("sampleCount") == stream.sampleCount && audio.number("durationMs") == stream.durationMs &&
                    manifest.object("meeting").number("durationMs") == stream.durationMs &&
                    shared.allSatisfy { (try? integrity.number($0)) != nil && (try? integrity.number($0)) == (try? audio.number($0)) }
                let digestMatches = sameBytes(digest, integrity["opusAudioSha256"]?.string)
                if !digestMatches { warnings.append("audio-digest-mismatch") }
                if !shapeMatches { warnings.append("audio-shape-mismatch") }
                state = digestMatches && shapeMatches ? .ok : .staleAudio
            } catch { warnings.append("audio-verification-unavailable") }
        }
        return CassiniDocument(state: state, manifest: manifest, variants: variants, comments: parsed.text,
                               opaqueComments: parsed.opaque, warnings: warnings)
    }

    private static func validateManifest(_ m: JSONObject) throws {
        try check(m["kind"] == .string("cassini-portable-meeting") && m.number("version") == 1 && m["profile"] == .string("ogg-opus"), "Unsupported manifest")
        let meeting = try m.object("meeting")
        try nonempty(meeting, "id"); try nonempty(meeting, "title"); _ = try meeting.number("durationMs")
        let created = try meeting.string("createdAtUtc")
        try check(created.hasSuffix("Z") && parseInstant(created) != nil, "Invalid createdAtUtc")
        let audio = try m.object("audio")
        try check(audio["container"] == .string("ogg") && audio["codec"] == .string("opus") && audio.number("sampleRate") == 48000, "Unsupported audio")
        try check((1...2).contains(audio.number("channels")), "Unsupported channel count")
        _ = try audio.number("sampleCount"); _ = try audio.number("durationMs")
        let integrity = try m.object("integrity")
        try nonempty(integrity, "matchPolicy")
        try check(fullMatch(integrity.string("opusAudioSha256"), "[0-9a-f]{64}"), "Invalid audio digest")
        for key in ["sampleRate", "channels", "sampleCount", "durationMs"] { _ = try integrity.number(key) }
        var speakerIds = Set<String>()
        for s in try m.array("speakers") {
            guard let s = s.object else { throw CassiniError("Malformed speaker") }
            try nonempty(s, "id"); try nonempty(s, "label")
            try check(speakerIds.insert(try s.string("id")).inserted, "Duplicate speaker")
        }
        let entries = try m.array("transcripts")
        try check((1...128).contains(entries.count), "Transcript count out of range")
        var ids = Set<String>(), prefixes = Set<String>()
        for entry in entries {
            guard let tx = entry.object else { throw CassiniError("Malformed transcript entry") }
            let id = try tx.string("id")
            try check(fullMatch(id, "[a-z0-9][a-z0-9-]{0,31}") && ids.insert(id).inserted, "Invalid transcript id")
            try nonempty(tx, "format")
            if let d = tx["default"] { try check(d.bool != nil, "Invalid default flag") }
            let ref = try tx.object("payloadRef")
            let prefix = asciiUppercased(try ref.string("prefix"))
            try check(fullMatch(prefix, "CASSINI_TX_[A-Z0-9_]+_PAYLOAD_") && prefixes.insert(prefix).inserted, "Invalid payload prefix")
            try nonempty(ref, "mime"); try nonempty(ref, "encoding"); try nonempty(ref, "sha256")
            try check((1...4096).contains(ref.number("chunkCount")), "Chunk count out of range")
            _ = try ref.number("rawBytes"); _ = try ref.number("gzipBytes")
        }
    }

    private static func nonempty(_ o: JSONObject, _ key: String) throws { try check(!(try o.string(key)).isEmpty, "Empty \(key)") }

    static func parseInstant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func decimal(_ value: String?) throws -> Int64 {
        guard let value = value, fullMatch(value, "0|[1-9][0-9]*"), let n = Int64(value), n <= 9007199254740991 else {
            throw CassiniError("Invalid decimal tag")
        }
        return n
    }

    private static func manifestRef(_ tags: [String: String]) throws -> JSONObject {
        var ref = JSONObject([("prefix", .string(manifestPrefix))])
        for (key, suffix) in fields {
            guard let tag = tags[manifestPrefix + suffix] else { throw CassiniError("Missing manifest descriptor") }
            ref[key] = ["chunkCount", "rawBytes", "gzipBytes"].contains(key) ? .int(try decimal(tag)) : .string(tag)
        }
        return ref
    }

    private static func payload(_ tags: [String: String], _ ref: JSONObject) throws -> String {
        try check(ref["encoding"] == .string(CassiniPayload.encoding), "Unsupported payload encoding")
        let prefix = asciiUppercased(try ref.string("prefix"))
        let count = try ref.number("chunkCount")
        try check((1...4096).contains(count), "Chunk count out of range")
        let chunks = try (0..<Int(count)).map { i -> String in
            let name = prefix + String(format: "%03d", i)
            guard let chunk = tags[name] else { throw CassiniError("chunk-missing: \(name)") }
            return chunk
        }
        return try CassiniPayload.decode(chunks, rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: ref.string("sha256"))
    }

    // MARK: Comment packets

    /** The comment entries of an OpusTags packet as stored, without decoding them. */
    static func rawComments(_ packet: [UInt8]) throws -> [[UInt8]] {
        try check(packet.count <= OggOpus.maxHeaderBytes, "OpusTags too large")
        var pos = 8
        func bytes() throws -> [UInt8] {
            try check(pos + 4 <= packet.count, "Truncated OpusTags")
            let size = Int(UInt32(bitPattern: OggOpus.u32(packet, pos))); pos += 4
            try check(size <= packet.count - pos, "Truncated OpusTags")
            defer { pos += size }
            return Array(packet[pos..<(pos + size)])
        }
        _ = try bytes() // Vendor is descriptive, never authoritative.
        try check(pos + 4 <= packet.count, "Truncated OpusTags")
        let count = Int(UInt32(bitPattern: OggOpus.u32(packet, pos))); pos += 4
        try check(count <= 20000, "Too many comments")
        return try (0..<count).map { _ in try bytes() }
    }

    /**
     * A comment list decoded one comment at a time. A foreign comment that is not UTF-8 (say a Latin-1 ARTIST from an
     * old tagger) is kept as bytes with a warning; a CASSINI_ comment that is not UTF-8 makes the metadata invalid.
     */
    struct TagComments {
        var text: [String] = []
        var opaque: [[UInt8]] = []
        var warnings: [String] = []

        init(packet: [UInt8]) throws {
            for entry in try rawComments(packet) {
                if let comment = try? utf8(entry) {
                    text.append(comment)
                    continue
                }
                let name = tagName(entry)
                try check(!name.hasPrefix("CASSINI_"), "invalid-utf8-tag: \(name)")
                opaque.append(entry)
                warnings.append("non-utf8-comment: \(name)")
            }
        }
    }

    public static func tagsPacket(_ comments: [String], opaque: [[UInt8]] = []) -> [UInt8] {
        let entries = comments.map { Array($0.utf8) } + opaque
        var out = Array("OpusTags".utf8)
        func length(_ n: Int) { var b = [UInt8](repeating: 0, count: 4); OggOpus.put32(&b, 0, Int32(n)); out += b }
        let vendor = Array(self.vendor.utf8)
        length(vendor.count); out += vendor; length(entries.count)
        for entry in entries { length(entry.count); out += entry }
        return out
    }

    /** [comments] with the first TITLE set to [title] where it stands and later ones dropped, or one appended. */
    static func withTitle(_ comments: [String], _ title: String) -> [String] {
        guard let first = comments.firstIndex(where: { tagName($0) == "TITLE" }) else { return comments + ["TITLE=\(title)"] }
        return comments.indices.compactMap { i in
            guard tagName(comments[i]) == "TITLE" else { return comments[i] }
            return i == first ? "TITLE=\(title)" : nil
        }
    }

    private static func isManifestTag(_ name: String) -> Bool {
        fields.contains { manifestPrefix + $0.suffix == name } || fullMatch(name, "CASSINI_PAYLOAD_[0-9]+")
    }

    /** Text comments and opaque ones, in the order they are written. */
    private struct Comments {
        var text: [String]
        var opaque: [[UInt8]]
        var packet: [UInt8] { tagsPacket(text, opaque: opaque) }

        /** These comments with one TITLE of [title]: an undecodable TITLE cannot stay beside it. */
        func titled(_ title: String) -> Comments {
            Comments(text: withTitle(text, title), opaque: opaque.filter { tagName($0) != "TITLE" })
        }
    }

    // MARK: Writing

    /** Adds a variant while retaining existing descriptors, bodies, extensions and unrelated tags. */
    public static func create(_ audioBytes: [UInt8], transcript: Transcript, title: String, processing: JSONObject,
                              existing: CassiniDocument? = nil, speakerLabels: [String: String] = [:]) throws -> [UInt8] {
        let (comments, digest) = try seal(OggOpus.scan(ArraySource(audioBytes)), transcript, title, processing, existing, speakerLabels)
        let out = ArraySink()
        try check(try OggOpus.rewrite(ArraySource(audioBytes), tags: comments.packet, to: out).digest() == digest, "Audio changed while sealing")
        try verify(read(out.bytes), transcript)
        return out.bytes
    }

    /** Streams [audio] into [target] behind the new tags and verifies the written file from disk; nothing is left on failure. */
    @discardableResult
    public static func create(_ audio: URL, transcript: Transcript, title: String, processing: JSONObject, existing: CassiniDocument?,
                              speakerLabels: [String: String], target: URL) throws -> CassiniDocument {
        let (comments, digest) = try seal(OggOpus.scan(audio), transcript, title, processing, existing, speakerLabels)
        do {
            try writeWithTags(audio, comments, digest, target)
            let sealed = read(target)
            try verify(sealed, transcript)
            return sealed
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /** Copies [source]'s audio packet for packet behind [comments]; the audio must still hash to [digest]. */
    private static func writeWithTags(_ source: URL, _ comments: Comments, _ digest: String, _ target: URL) throws {
        try check(try OggOpus.rewrite(source, tags: comments.packet, to: target).digest() == digest, "Audio changed while sealing")
    }

    /**
     * Renames speakers only: bodies, variants, unknown members and unrelated tags stay as they are, and the
     * manifest tags are re-encoded. The written file must read back identical apart from those labels.
     */
    @discardableResult
    public static func relabel(_ source: URL, existing: CassiniDocument, labels: [String: String], target: URL) throws -> CassiniDocument {
        guard existing.state == .ok, var manifest = existing.manifest else { throw CassiniError("Only a verified document can be relabelled") }
        var speakers = try manifest.array("speakers")
        for (id, label) in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try check(!trimmed.isEmpty, "Blank label")
            guard let i = speakers.firstIndex(where: { $0.object?["id"]?.string == id }), var speaker = speakers[i].object else {
                throw CassiniError("Unknown speaker \(id)")
            }
            speaker["label"] = .string(trimmed)
            speakers[i] = .object(speaker)
        }
        manifest["speakers"] = .array(speakers)
        let foreign = Comments(text: existing.comments.filter { !isManifestTag(tagName($0)) }, opaque: existing.opaqueComments)
        return try rewriteManifest(source, existing: existing, manifest: manifest, comments: foreign, target: target)
    }

    /**
     * Renames the meeting only: sets `meeting.title` and the TITLE tag to the trimmed [title]. The first TITLE tag is
     * replaced where it stands, further ones are dropped, and one is added when there is none. Bodies, variants,
     * unknown members, other tags and the audio stay as they are. The written file must read back identical apart
     * from the title.
     */
    @discardableResult
    public static func retitle(_ source: URL, existing: CassiniDocument, title: String, target: URL) throws -> CassiniDocument {
        guard existing.state == .ok, var manifest = existing.manifest else { throw CassiniError("Only a verified document can be retitled") }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(!clean.isEmpty, "Blank title")
        var meeting = try manifest.object("meeting")
        meeting["title"] = .string(clean)
        manifest["meeting"] = .object(meeting)
        let titled = Comments(text: existing.comments.filter { !isManifestTag(tagName($0)) }, opaque: existing.opaqueComments)
            .titled(clean)
        return try rewriteManifest(source, existing: existing, manifest: manifest, comments: titled, target: target)
    }

    /**
     * Writes [source]'s audio behind [comments] and the re-encoded [manifest], then reads the file back: it must
     * verify and carry exactly that manifest, those comments and every variant body of [existing]. Nothing is left at
     * [target] on failure.
     */
    private static func rewriteManifest(_ source: URL, existing: CassiniDocument, manifest: JSONObject, comments: Comments,
                                        target: URL) throws -> CassiniDocument {
        let digest = try manifest.object("integrity").string("opusAudioSha256")
        let manifestTags = try CassiniPayload.encode(prefix: manifestPrefix, mime: CassiniPayload.mime, text: manifest.serialized()).tags
        do {
            try writeWithTags(source, Comments(text: comments.text + manifestTags, opaque: comments.opaque), digest, target)
            let written = read(target)
            try check(written.state == .ok && written.manifest == manifest, "Rewritten manifest does not read back")
            try check(written.variants.map { $0.id } == existing.variants.map { $0.id } &&
                      written.variants.map { $0.body } == existing.variants.map { $0.body }, "Rewritten transcripts do not read back")
            try check(written.comments.filter { !isManifestTag(tagName($0)) } == comments.text &&
                      written.opaqueComments == comments.opaque, "Rewritten tags do not read back")
            return written
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private static func verify(_ sealed: CassiniDocument, _ transcript: Transcript) throws {
        try check(sealed.state == .ok && sealed.selected()?.transcript == transcript, "Sealed document does not read back")
    }

    /**
     * The comments and audio digest of [stream] with [transcript] added as the new default variant. Beside a verified
     * [existing] document only the copies it rewrites are replaced. Without one no CASSINI_ tag of the source can be
     * trusted to match the new manifest, so all of them are dropped; foreign comments always survive. TITLE follows
     * `meeting.title`.
     */
    private static func seal(_ stream: OggOpus.Info, _ transcript: Transcript, _ title: String, _ processing: JSONObject,
                             _ existing: CassiniDocument?, _ speakerLabels: [String: String]) throws -> (comments: Comments, digest: String) {
        let digest = try stream.digest()
        try check(existing == nil || existing!.state == .ok, "Never rebind stale transcripts to different audio")
        let now = now()
        let shape: [(String, JSON)] = [("sampleRate", .int(48000)), ("channels", .int(stream.channels)),
                                       ("sampleCount", .int(stream.sampleCount)), ("durationMs", .int(stream.durationMs))]
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var manifest = existing?.manifest ?? JSONObject([
            ("kind", .string("cassini-portable-meeting")), ("version", .int(1)), ("profile", .string("ogg-opus")),
            ("meeting", .object(JSONObject([("id", .string("mtg_" + UUID().uuidString.lowercased())),
                                            ("title", .string(trimmedTitle.isEmpty ? "Recording" : trimmedTitle)),
                                            ("createdAtUtc", .string(now)), ("durationMs", .int(stream.durationMs))]))),
            ("audio", .object(JSONObject([("container", .string("ogg")), ("codec", .string("opus")), ("sampleRate", .int(48000)),
                                          ("channels", .int(stream.channels)), ("sampleCount", .int(stream.sampleCount)),
                                          ("durationMs", .int(stream.durationMs))]))),
            ("integrity", .object(JSONObject([("matchPolicy", .string(matchPolicy)), ("opusAudioSha256", .string(digest))] + shape))),
            ("speakers", .array([])), ("transcripts", .array([])),
        ])
        var descriptors = try manifest.array("transcripts")
        let id = descriptors.isEmpty ? "words" : "words-" + UUID().uuidString.lowercased().prefix(8)
        descriptors = descriptors.map { d in
            guard var o = d.object else { return d }
            o["default"] = .bool(false)
            return .object(o)
        }
        let prefix = "CASSINI_TX_" + id.uppercased().replacingOccurrences(of: "-", with: "_") + "_PAYLOAD_"
        let (ref, bodyTags) = try CassiniPayload.encode(prefix: prefix, mime: CassiniPayload.wordMime, text: transcript.json())
        var descriptor = JSONObject([("id", .string(id)), ("format", .string(Transcript.format)), ("default", .bool(true))])
        if !transcript.language.isEmpty { descriptor["language"] = .string(transcript.language) }
        descriptor["wordCount"] = .int(transcript.words.count)
        descriptor["createdAtUtc"] = .string(now)
        descriptor["payloadRef"] = .object(ref)
        descriptors.append(.object(descriptor))
        manifest["transcripts"] = .array(descriptors)
        var speakers = try manifest.array("speakers")
        var known = Set(speakers.compactMap { $0.object?["id"]?.string })
        for word in transcript.words where known.insert(word.speaker).inserted {
            speakers.append(.object(JSONObject([("id", .string(word.speaker)), ("label", .string(speakerLabels[word.speaker] ?? word.speaker))])))
        }
        manifest["speakers"] = .array(speakers)
        var provenance = manifest["provenance"]?.object ?? JSONObject()
        var speech = provenance["speechToText"]?.object ?? JSONObject()
        speech[id] = .object(processing)
        provenance["speechToText"] = .object(speech)
        // This document-wide record describes cross-track crosstalk auditing, not
        // clustering a mixed recording. Preserve an imported audit exactly as supplied.
        if existing == nil {
            provenance["attribution"] = .object(JSONObject([("ran", .bool(false)), ("mode", .string("single-source")),
                                                            ("reason", .string("Single mixed recording; no separate speaker tracks")),
                                                            ("wordsMeasured", .int(0)), ("wordsFlagged", .int(0)), ("wordsDropped", .int(0))]))
        }
        manifest["provenance"] = .object(provenance)
        var comments: Comments
        if let existing {
            comments = Comments(text: existing.comments.filter { !resealed.contains(tagName($0)) && !isManifestTag(tagName($0)) },
                                opaque: existing.opaqueComments)
        } else {
            let foreign = try rawComments(stream.tags).filter { !tagName($0).hasPrefix("CASSINI_") }
            comments = Comments(text: foreign.compactMap { try? utf8($0) }, opaque: foreign.filter { (try? utf8($0)) == nil })
        }
        let meeting = try manifest.object("meeting")
        comments = comments.titled(try meeting.string("title"))
        let ids = descriptors.compactMap { $0.object?["id"]?.string }.sorted().joined(separator: ",")
        comments.text += ["CASSINI_FORMAT=\(format)", "CASSINI_PROFILE=ogg-opus", "CASSINI_PAYLOAD_SCHEMA=\(schema)",
                          "CASSINI_TRANSCRIPT_IDS=\(ids)", "CASSINI_TRANSCRIPT_DEFAULT=\(id)", "CASSINI_SPEAKER_COUNT=\(speakers.count)",
                          "CASSINI_MEETING_ID=\(try meeting.string("id"))", "CASSINI_CREATED_AT=\(try meeting.string("createdAtUtc"))",
                          "CASSINI_DECODE_HINT=Concatenate CASSINI_PAYLOAD_000..N for the manifest; for a transcript body concatenate CASSINI_TX_<ID>_PAYLOAD_000..N. Each chunk set: base64url decode, gzip decompress, parse UTF-8 JSON."]
        for (key, value) in [("SAMPLE_RATE", "48000"), ("CHANNELS", String(stream.channels)), ("SAMPLE_COUNT", String(stream.sampleCount)),
                             ("DURATION_MS", String(stream.durationMs)), ("MATCH_POLICY", matchPolicy), ("OPUS_SHA256", digest)] {
            comments.text.append("CASSINI_AUDIO_\(key)=\(value)")
        }
        comments.text += bodyTags
        comments.text += try CassiniPayload.encode(prefix: manifestPrefix, mime: CassiniPayload.mime, text: manifest.serialized()).tags
        return (comments, digest)
    }
}
