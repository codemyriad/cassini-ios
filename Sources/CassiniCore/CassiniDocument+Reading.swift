import Foundation

/** Reading a document: the Ogg stream, its tags and manifest, checked against each other and against the audio. */
extension CassiniDocument {
    public static func read(_ bytes: [UInt8]) -> CassiniDocument { read(verify: true, reportsIOErrors: false) { ArraySource(bytes) } }
    /** Streams [url]; without [verify] only the headers are read and the audio stays unverified. */
    public static func read(_ url: URL, verify: Bool = true) -> CassiniDocument {
        read(verify: verify, reportsIOErrors: false) { try FileSource(url) }
    }

    /** [reportsIOErrors] makes a file that cannot be opened or read [DocumentState.unreadable] instead of plain audio. */
    static func read(verify: Bool, reportsIOErrors: Bool, decodeTranscripts: Bool = true,
                     open: () throws -> ByteSource) -> CassiniDocument {
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
        var tags = TagValues()
        var duplicates: [String] = []
        for comment in parsed.text {
            let utf8 = comment.utf8
            guard let equals = utf8.firstIndex(of: UInt8(ascii: "=")), equals != utf8.startIndex else { continue }
            let name = asciiUppercased(utf8[..<equals])
            let value = String(decoding: utf8[utf8.index(after: equals)...], as: UTF8.self)
            if tags.set(name, value) &&
                (sameBytes(name, "CASSINI_FORMAT") || hasBytePrefix(name, manifestPrefix) || hasBytePrefix(name, "CASSINI_TX_")) { duplicates.append(name) }
        }
        // Only a file that names itself Cassini can have invalid Cassini metadata; anything else is plain audio.
        guard tags["CASSINI_FORMAT"] != nil || parsed.undecodableCassiniNames.contains("CASSINI_FORMAT") else { return document }
        if !parsed.undecodableCassiniNames.isEmpty {
            document.state = .invalidMetadata
            document.warnings += parsed.undecodableCassiniNames.map { "invalid-utf8-tag: \($0)" }
            return document
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
            guard decodeTranscripts else {
                return Variant(id: id, descriptor: descriptor, body: nil, transcript: nil)
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
        for (suffix, field) in audioMirrors where !sameBytes(tags["CASSINI_AUDIO_\(suffix)"], integrity[field]?.text) {
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

    static func validateManifest(_ m: JSONObject) throws {
        try check(m["kind"] == .string("cassini-portable-meeting") && m.number("version") == 1 && m["profile"] == .string("ogg-opus"), "Unsupported manifest")
        let meeting = try m.object("meeting")
        try nonempty(meeting, "id"); try nonempty(meeting, "title"); _ = try meeting.number("durationMs")
        let created = try meeting.string("createdAtUtc")
        try check(created.hasSuffix("Z") && parseInstant(created) != nil, "Invalid createdAtUtc")
        // Optional meeting-time metadata is interpreted by readers, not load-bearing transcript
        // schema. An unusable recordedAtUtc must allow DATE/local fallback without hiding words.
        let audio = try m.object("audio")
        try check(audio["container"] == .string("ogg") && audio["codec"] == .string("opus") && audio.number("sampleRate") == 48000, "Unsupported audio")
        try check((1...2).contains(audio.number("channels")), "Unsupported channel count")
        _ = try audio.number("sampleCount"); _ = try audio.number("durationMs")
        let integrity = try m.object("integrity")
        try nonempty(integrity, "matchPolicy")
        try check(fullMatch(integrity.string("opusAudioSha256"), "[0-9a-f]{64}"), "Invalid audio digest")
        for key in ["sampleRate", "channels", "sampleCount", "durationMs"] { _ = try integrity.number(key) }
        var speakerIds = Set<[UInt8]>()
        for s in try m.array("speakers") {
            guard let s = s.object else { throw CassiniError("Malformed speaker") }
            try nonempty(s, "id"); try nonempty(s, "label")
            try check(speakerIds.insert(Array(try s.string("id").utf8)).inserted, "Duplicate speaker")
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

    static func nonempty(_ o: JSONObject, _ key: String) throws { try check(!(try o.string(key)).isEmpty, "Empty \(key)") }

    /// Offset-bearing RFC3339, shared by meeting-time readers and writers. Preserve legacy separator/case
    /// compatibility and the pinned reference reader's microsecond precision when comparing instants.
    public static func parseInstant(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = rfc3339Instant.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let date = part(1), let clock = part(2), let zone = part(4) else { return nil }
        // Match cassini-format 32f37a6's pure reader: RFC3339 separators/offsets and microsecond precision.
        let fraction = part(3).map { String($0.prefix(7)) } ?? ""
        let normalized = "\(date)T\(clock)\(fraction)\(zone.uppercased())"
        return (try? Date(normalized, strategy: .iso8601))
            ?? (try? Date(normalized, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private static let rfc3339Instant = try! NSRegularExpression(
        pattern: #"^([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt ]([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"#)
    static func now() -> String { instantText(Date()) }

    static func instantText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decimal(_ value: String?) throws -> Int64 {
        guard let value = value, fullMatch(value, "0|[1-9][0-9]*"), let n = Int64(value), n <= 9007199254740991 else {
            throw CassiniError("Invalid decimal tag")
        }
        return n
    }

    /** Comment values by tag name. Names are ASCII upper case already and compare by their bytes, as values do. */
    struct TagValues {
        private var values: [[UInt8]: String] = [:]

        subscript(name: String) -> String? { values[Array(name.utf8)] }

        /** Records [value] under [name] and says whether the name was already there. */
        mutating func set(_ name: String, _ value: String) -> Bool { values.updateValue(value, forKey: Array(name.utf8)) != nil }
    }

    static func manifestRef(_ tags: TagValues) throws -> JSONObject {
        var ref = JSONObject([("prefix", .string(manifestPrefix))])
        for (key, suffix) in fields {
            guard let tag = tags[manifestPrefix + suffix] else { throw CassiniError("Missing manifest descriptor") }
            ref[key] = ["chunkCount", "rawBytes", "gzipBytes"].contains(key) ? .int(try decimal(tag)) : .string(tag)
        }
        return ref
    }

    static func payload(_ tags: TagValues, _ ref: JSONObject) throws -> String {
        try check(ref["encoding"] == .string(CassiniPayload.encoding), "Unsupported payload encoding")
        let prefix = asciiUppercased(try ref.string("prefix"))
        let count = try ref.number("chunkCount")
        try check((1...4096).contains(count), "Chunk count out of range")
        let chunks = try (0..<Int(count)).map { i -> String in
            let name = prefix + String(format: "%03d", i)
            guard let chunk = tags[name] else { throw CassiniError("chunk-missing: \(name)") }
            return chunk
        }
        do {
            return try CassiniPayload.decode(chunks, rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: ref.string("sha256"))
        } catch let error as CassiniError where error.message == "payload-sha256-mismatch" {
            throw CassiniError("\(error.message): \(prefix)SHA256")
        } catch let error as CassiniError where error.message == "payload-size-mismatch" {
            throw CassiniError("\(error.message): \(prefix)RAW_BYTES")
        }
    }
}
