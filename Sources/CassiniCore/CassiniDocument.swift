import Foundation

/** The portable document is authoritative; Transcript is only a selected viewer projection. */
public struct CassiniDocument {
    public var state: String
    public var manifest: JSONObject?
    public var variants: [Variant] = []
    public var comments: [String] = []
    public var warnings: [String] = []

    public struct Variant {
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
    private static let manifestPrefix = "CASSINI_PAYLOAD_"
    private static let integrityKeys: Set<String> = ["matchPolicy", "opusAudioSha256", "sampleRate", "channels", "sampleCount", "durationMs"]
    private static let refKeys: Set<String> = ["prefix", "mime", "encoding", "chunkCount", "sha256", "rawBytes", "gzipBytes"]
    private static let fields: [(key: String, suffix: String)] = [("mime", "MIME"), ("encoding", "ENCODING"), ("chunkCount", "CHUNK_COUNT"),
                                                                  ("sha256", "SHA256"), ("rawBytes", "RAW_BYTES"), ("gzipBytes", "GZIP_BYTES")]

    static func tagName(_ comment: String) -> String {
        String(comment[..<(comment.firstIndex(of: "=") ?? comment.endIndex)]).uppercased()
    }

    public static func read(_ bytes: [UInt8]) -> CassiniDocument { read(verify: true) { ArraySource(bytes) } }
    /** Streams [url]; without [verify] only the headers are read and the audio stays unverified. */
    public static func read(_ url: URL, verify: Bool = true) -> CassiniDocument { read(verify: verify) { try FileSource(url) } }

    private static func read(verify: Bool, open: () throws -> ByteSource) -> CassiniDocument {
        // Audio corruption must not conceal an otherwise intact manifest/transcript.
        guard let (head, tagPacket) = try? OggOpus.headers(open()) else { return CassiniDocument(state: "plain-audio") }
        guard let comments = try? readComments(tagPacket) else { return CassiniDocument(state: "invalid-cassini-metadata") }
        var tags: [String: String] = [:]
        var duplicates: [String] = []
        for comment in comments {
            guard let equals = comment.firstIndex(of: "="), equals != comment.startIndex else { continue }
            let name = String(comment[..<equals]).uppercased()
            if tags.updateValue(String(comment[comment.index(after: equals)...]), forKey: name) != nil &&
                (name == "CASSINI_FORMAT" || name.hasPrefix(manifestPrefix) || name.hasPrefix("CASSINI_TX_")) { duplicates.append(name) }
        }
        guard let format = tags["CASSINI_FORMAT"] else { return CassiniDocument(state: "plain-audio", comments: comments) }
        if !duplicates.isEmpty { return CassiniDocument(state: "invalid-cassini-metadata", comments: comments, warnings: duplicates) }
        if format != self.format { return CassiniDocument(state: "unknown-cassini-format", comments: comments) }
        var warnings: [String] = []
        let manifest: JSONObject
        do {
            try check(tags["CASSINI_PROFILE"] == "ogg-opus" && tags["CASSINI_PAYLOAD_MIME"] == CassiniPayload.mime, "Unsupported profile")
            try check(tags["CASSINI_PAYLOAD_SCHEMA"] == schema, "Unsupported schema")
            manifest = try JSON.parseObject(payload(tags, manifestRef(tags)))
            try validateManifest(manifest)
        } catch {
            return CassiniDocument(state: "invalid-cassini-metadata", comments: comments, warnings: ["\(error)"])
        }
        let descriptors = (try? manifest.array("transcripts")) ?? []
        let variants: [Variant] = descriptors.compactMap { $0.object }.map { descriptor in
            let id = descriptor["id"]?.string ?? ""
            let ref = descriptor["payloadRef"]?.object ?? JSONObject()
            let prefix = (ref["prefix"]?.string ?? "").uppercased()
            for (field, suffix) in fields where tags[prefix + suffix] != ref[field]?.text {
                warnings.append("tag-manifest-disagreement: \(prefix)\(suffix)")
            }
            do {
                try check(Set(ref.keys) == refKeys && descriptor["format"] == .string("cassini.words.v1"), "Unsupported transcript")
                try check(ref["mime"] == .string(CassiniPayload.wordMime), "Unsupported transcript")
                let body = try payload(tags, ref)
                return Variant(id: id, descriptor: descriptor, body: body, transcript: try Transcript.fromJSON(body))
            } catch {
                return Variant(id: id, descriptor: descriptor, body: nil, transcript: nil, error: "\(error)")
            }
        }
        let defaultVariant = (variants.first { $0.descriptor["default"] == .bool(true) } ?? variants[0]).id
        if tags["CASSINI_TRANSCRIPT_IDS"] != variants.map({ $0.id }).sorted().joined(separator: ",") {
            warnings.append("tag-manifest-disagreement: CASSINI_TRANSCRIPT_IDS")
        }
        if tags["CASSINI_TRANSCRIPT_DEFAULT"] != defaultVariant { warnings.append("tag-manifest-disagreement: CASSINI_TRANSCRIPT_DEFAULT") }
        let integrity = (try? manifest.object("integrity")) ?? JSONObject()
        let audio = (try? manifest.object("audio")) ?? JSONObject()
        let mirrors = [("SAMPLE_RATE", "sampleRate"), ("CHANNELS", "channels"), ("SAMPLE_COUNT", "sampleCount"),
                       ("DURATION_MS", "durationMs"), ("MATCH_POLICY", "matchPolicy"), ("OPUS_SHA256", "opusAudioSha256")]
        for (suffix, field) in mirrors where tags["CASSINI_AUDIO_\(suffix)"] != integrity[field]?.text {
            warnings.append("tag-manifest-disagreement: CASSINI_AUDIO_\(suffix)")
        }
        var state = "unverified"
        if verify && Set(integrity.keys) == integrityKeys && integrity["matchPolicy"] == .string("exact-opus-audio-v1") && warnings.isEmpty {
            do {
                let stream = try OggOpus.scan(open())
                try check(stream.head == head, "OpusHead changed")
                let digest = try stream.digest()
                let shared = ["sampleRate", "channels", "sampleCount", "durationMs"]
                let shapeMatches = try audio.number("sampleRate") == 48000 && audio.number("channels") == Int64(stream.channels) &&
                    audio.number("sampleCount") == stream.sampleCount && audio.number("durationMs") == stream.durationMs &&
                    manifest.object("meeting").number("durationMs") == stream.durationMs &&
                    shared.allSatisfy { (try? integrity.number($0)) != nil && (try? integrity.number($0)) == (try? audio.number($0)) }
                state = digest == integrity["opusAudioSha256"]?.string && shapeMatches ? "ok" : "stale-audio"
            } catch { warnings.append("audio-verification-unavailable") }
        }
        return CassiniDocument(state: state, manifest: manifest, variants: variants, comments: comments, warnings: warnings)
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
            let prefix = try ref.string("prefix").uppercased()
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
        let prefix = try ref.string("prefix").uppercased()
        let count = try ref.number("chunkCount")
        try check((1...4096).contains(count), "Chunk count out of range")
        let chunks = try (0..<Int(count)).map { i -> String in
            guard let chunk = tags[prefix + String(format: "%03d", i)] else { throw CassiniError("Missing chunk \(prefix)\(i)") }
            return chunk
        }
        return try CassiniPayload.decode(chunks, rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: ref.string("sha256"))
    }

    static func readComments(_ packet: [UInt8]) throws -> [String] {
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
        return try (0..<count).map { _ in try utf8(bytes()) }
    }

    public static func tagsPacket(_ comments: [String]) -> [UInt8] {
        var out = Array("OpusTags".utf8)
        func length(_ n: Int) { var b = [UInt8](repeating: 0, count: 4); OggOpus.put32(&b, 0, Int32(n)); out += b }
        let vendor = Array(self.vendor.utf8)
        length(vendor.count); out += vendor; length(comments.count)
        for comment in comments { let b = Array(comment.utf8); length(b.count); out += b }
        return out
    }

    /** Adds a variant while retaining existing descriptors, bodies, extensions and unrelated tags. */
    public static func create(_ audioBytes: [UInt8], transcript: Transcript, title: String, processing: JSONObject,
                              existing: CassiniDocument? = nil, speakerLabels: [String: String] = [:]) throws -> [UInt8] {
        let (comments, digest) = try seal(OggOpus.scan(ArraySource(audioBytes)), transcript, title, processing, existing, speakerLabels)
        let out = ArraySink()
        try check(try OggOpus.rewrite(ArraySource(audioBytes), tags: tagsPacket(comments), to: out).digest() == digest, "Audio changed while sealing")
        try verify(read(out.bytes), transcript)
        return out.bytes
    }

    /** Streams [audio] into [target] behind the new tags and verifies the written file from disk. */
    @discardableResult
    public static func create(_ audio: URL, transcript: Transcript, title: String, processing: JSONObject, existing: CassiniDocument?,
                              speakerLabels: [String: String], target: URL) throws -> CassiniDocument {
        let (comments, digest) = try seal(OggOpus.scan(audio), transcript, title, processing, existing, speakerLabels)
        try writeWithTags(audio, comments, digest, target)
        let sealed = read(target)
        try verify(sealed, transcript)
        return sealed
    }

    /** Copies [source]'s audio packet for packet behind [comments]; the audio must still hash to [digest]. */
    private static func writeWithTags(_ source: URL, _ comments: [String], _ digest: String, _ target: URL) throws {
        try check(try OggOpus.rewrite(source, tags: tagsPacket(comments), to: target).digest() == digest, "Audio changed while sealing")
    }

    /**
     * Renames speakers only: bodies, variants, unknown members and unrelated tags stay as they are, and the
     * manifest tags are re-encoded. The written file must read back identical apart from those labels.
     */
    @discardableResult
    public static func relabel(_ source: URL, existing: CassiniDocument, labels: [String: String], target: URL) throws -> CassiniDocument {
        guard existing.state == "ok", var manifest = existing.manifest else { throw CassiniError("Only a verified document can be relabelled") }
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
        let digest = try manifest.object("integrity").string("opusAudioSha256")
        let comments = existing.comments.filter { !isManifestTag(tagName($0)) } +
            (try CassiniPayload.encode(prefix: manifestPrefix, mime: CassiniPayload.mime, text: manifest.serialized())).tags
        do {
            try writeWithTags(source, comments, digest, target)
            let sealed = read(target)
            try check(sealed.state == "ok" && sealed.manifest == manifest, "Relabelled document does not read back")
            try check(sealed.variants.map { $0.id } == existing.variants.map { $0.id } &&
                      sealed.variants.map { $0.body } == existing.variants.map { $0.body }, "Relabelled document does not read back")
            return sealed
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private static func isManifestTag(_ name: String) -> Bool {
        fields.contains { manifestPrefix + $0.suffix == name } || fullMatch(name, "CASSINI_PAYLOAD_[0-9]+")
    }

    private static func verify(_ sealed: CassiniDocument, _ transcript: Transcript) throws {
        try check(sealed.state == "ok" && sealed.selected()?.transcript == transcript, "Sealed document does not read back")
    }

    private static func seal(_ stream: OggOpus.Info, _ transcript: Transcript, _ title: String, _ processing: JSONObject,
                             _ existing: CassiniDocument?, _ speakerLabels: [String: String]) throws -> (comments: [String], digest: String) {
        let digest = try stream.digest()
        try check(existing == nil || existing!.state == "ok", "Never rebind stale transcripts to different audio")
        let now = now()
        let shape: [(String, JSON)] = [("sampleRate", .int(48000)), ("channels", .int(stream.channels)),
                                       ("sampleCount", .int(stream.sampleCount)), ("durationMs", .int(stream.durationMs))]
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var manifest = existing?.manifest ?? JSONObject([
            ("kind", .string("cassini-portable-meeting")), ("version", .int(1)), ("profile", .string("ogg-opus")),
            ("meeting", .object(JSONObject([("id", .string("mtg_" + UUID().uuidString.lowercased())),
                                            ("title", .string(trimmedTitle.isEmpty ? "Recording" : title)),
                                            ("createdAtUtc", .string(now)), ("durationMs", .int(stream.durationMs))]))),
            ("audio", .object(JSONObject([("container", .string("ogg")), ("codec", .string("opus")), ("sampleRate", .int(48000)),
                                          ("channels", .int(stream.channels)), ("sampleCount", .int(stream.sampleCount)),
                                          ("durationMs", .int(stream.durationMs))]))),
            ("integrity", .object(JSONObject([("matchPolicy", .string("exact-opus-audio-v1")), ("opusAudioSha256", .string(digest))] + shape))),
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
        descriptors.append(.object(JSONObject([("id", .string(id)), ("format", .string("cassini.words.v1")), ("default", .bool(true)),
                                               ("language", .string(transcript.language)), ("wordCount", .int(transcript.words.count)),
                                               ("createdAtUtc", .string(now)), ("payloadRef", .object(ref))])))
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
        let replaced: Set<String> = ["CASSINI_FORMAT", "CASSINI_PROFILE", "CASSINI_PAYLOAD_SCHEMA", "CASSINI_TRANSCRIPT_IDS",
                                     "CASSINI_TRANSCRIPT_DEFAULT", "CASSINI_DECODE_HINT", "CASSINI_SPEAKER_COUNT", "CASSINI_MEETING_ID",
                                     "CASSINI_CREATED_AT", "CASSINI_AUDIO_SAMPLE_RATE", "CASSINI_AUDIO_CHANNELS", "CASSINI_AUDIO_SAMPLE_COUNT",
                                     "CASSINI_AUDIO_DURATION_MS", "CASSINI_AUDIO_MATCH_POLICY", "CASSINI_AUDIO_OPUS_SHA256"]
        var comments = try (existing?.comments ?? readComments(stream.tags)).filter {
            let name = tagName($0)
            return !replaced.contains(name) && !isManifestTag(name)
        }
        let meeting = try manifest.object("meeting")
        let ids = descriptors.compactMap { $0.object?["id"]?.string }.sorted().joined(separator: ",")
        comments += ["CASSINI_FORMAT=\(format)", "CASSINI_PROFILE=ogg-opus", "CASSINI_PAYLOAD_SCHEMA=\(schema)",
                     "CASSINI_TRANSCRIPT_IDS=\(ids)", "CASSINI_TRANSCRIPT_DEFAULT=\(id)", "CASSINI_SPEAKER_COUNT=\(speakers.count)",
                     "CASSINI_MEETING_ID=\(try meeting.string("id"))", "CASSINI_CREATED_AT=\(try meeting.string("createdAtUtc"))",
                     "CASSINI_DECODE_HINT=Concatenate CASSINI_PAYLOAD_000..N for the manifest; for a transcript body concatenate CASSINI_TX_<ID>_PAYLOAD_000..N. Each chunk set: base64url decode, gzip decompress, parse UTF-8 JSON."]
        for (key, value) in [("SAMPLE_RATE", "48000"), ("CHANNELS", String(stream.channels)), ("SAMPLE_COUNT", String(stream.sampleCount)),
                             ("DURATION_MS", String(stream.durationMs)), ("MATCH_POLICY", "exact-opus-audio-v1"), ("OPUS_SHA256", digest)] {
            comments.append("CASSINI_AUDIO_\(key)=\(value)")
        }
        if existing == nil && !comments.contains(where: { tagName($0) == "TITLE" }) { comments.append("TITLE=\(try meeting.string("title"))") }
        comments += bodyTags
        comments += try CassiniPayload.encode(prefix: manifestPrefix, mime: CassiniPayload.mime, text: manifest.serialized()).tags
        return (comments, digest)
    }
}
