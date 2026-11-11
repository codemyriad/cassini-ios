import Foundation

/** The comment packet of a document: its raw comments, the foreign ones a write keeps, and the tags it derives. */
extension CassiniDocument {
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
     * A comment list decoded one comment at a time. A comment that is not UTF-8 (say a Latin-1 ARTIST from an old
     * tagger) is kept as bytes with a warning. One named CASSINI_ is also listed in [undecodableCassiniNames]: it makes
     * the metadata invalid, but only in a file that turns out to be Cassini at all.
     */
    struct TagComments {
        var text: [String] = []
        var opaque: [[UInt8]] = []
        var warnings: [String] = []
        var undecodableCassiniNames: [String] = []

        init(packet: [UInt8]) throws {
            for entry in try rawComments(packet) {
                if let comment = try? utf8(entry) {
                    text.append(comment)
                    continue
                }
                let name = tagName(entry)
                if hasBytePrefix(name, "CASSINI_") { undecodableCassiniNames.append(name) }
                opaque.append(entry)
                warnings.append("non-utf8-comment: \(name)")
            }
        }
    }

    /** The comments of the OpusTags packet [tags] that a seal without an existing document keeps: all but `CASSINI_*`. */
    static func foreignComments(_ tags: [UInt8]) throws -> (text: [String], opaque: [[UInt8]]) {
        let foreign = try rawComments(tags).filter { !hasBytePrefix(tagName($0), "CASSINI_") }
        return (foreign.compactMap { try? utf8($0) }, foreign.filter { (try? utf8($0)) == nil })
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
        guard let first = comments.firstIndex(where: { isTitle($0) }) else { return comments + ["TITLE=\(title)"] }
        return comments.indices.compactMap { i in
            guard isTitle(comments[i]) else { return comments[i] }
            return i == first ? "TITLE=\(title)" : nil
        }
    }

    static func isTitle(_ comment: String) -> Bool { sameBytes(tagName(comment), "TITLE") }

    static func isManifestTag(_ name: String) -> Bool {
        fields.contains { sameBytes(manifestPrefix + $0.suffix, name) } || fullMatch(name, "CASSINI_PAYLOAD_[0-9]+")
    }

    /**
     * Whether a write replaces the comment named [name] with one derived from its manifest: the manifest chunk set,
     * a summary or mirror copy, or the descriptor copy of any transcript chunk set. Transcript chunks are not derived.
     */
    static func isDerived(_ name: String) -> Bool {
        derivedNames.contains(Array(name.utf8)) || isManifestTag(name) ||
            fullMatch(name, "CASSINI_TX_[A-Z0-9_]+_PAYLOAD_(MIME|ENCODING|CHUNK_COUNT|SHA256|RAW_BYTES|GZIP_BYTES)")
    }

    /** Every copy of a [manifest] value, so that the tags of a written file agree with its manifest by construction. */
    static func copies(of manifest: JSONObject) throws -> [String] {
        let meeting = try manifest.object("meeting"), integrity = try manifest.object("integrity")
        let descriptors = try manifest.array("transcripts").compactMap { $0.object }
        let ids = descriptors.compactMap { $0["id"]?.string }
        let defaultId = (descriptors.first { $0["default"] == .bool(true) } ?? descriptors.first)?["id"]?.string ?? ""
        var tags = ["CASSINI_FORMAT=\(format)", "CASSINI_PROFILE=ogg-opus", "CASSINI_PAYLOAD_SCHEMA=\(schema)",
                    "CASSINI_TRANSCRIPT_IDS=\(ids.sorted().joined(separator: ","))", "CASSINI_TRANSCRIPT_DEFAULT=\(defaultId)",
                    "CASSINI_SPEAKER_COUNT=\(try manifest.array("speakers").count)", "CASSINI_MEETING_ID=\(try meeting.string("id"))",
                    "CASSINI_CREATED_AT=\(try meeting.string("createdAtUtc"))"]
        for (tag, field) in meetingMirrors {
            switch meeting[field] {
            case .string(let value) where !value.isEmpty: tags.append("\(tag)=\(value)")
            case .number(let value): tags.append("\(tag)=\(value)")
            default: break
            }
        }
        tags.append("CASSINI_DECODE_HINT=\(decodeHint)")
        for (suffix, field) in audioMirrors {
            guard let value = integrity[field] else { throw CassiniError("Missing integrity \(field)") }
            tags.append("CASSINI_AUDIO_\(suffix)=\(value.text)")
        }
        for descriptor in descriptors {
            guard let ref = descriptor["payloadRef"]?.object, let prefix = ref["prefix"]?.string.map(asciiUppercased) else { continue }
            for (field, suffix) in fields { if let value = ref[field] { tags.append("\(prefix)\(suffix)=\(value.text)") } }
        }
        return tags
    }

    /** The manifest's own chunk set, which is the record for [manifest] itself. */
    static func manifestTags(_ manifest: JSONObject) throws -> [String] {
        try CassiniPayload.encode(prefix: manifestPrefix, mime: CassiniPayload.mime, text: manifest.serialized()).tags
    }

    /** Whether no copy of [document] disagrees with its manifest. A writer must never ship one that does. */
    static func agreesWithManifest(_ document: CassiniDocument) -> Bool {
        !document.warnings.contains { $0.hasPrefix("tag-manifest-disagreement") }
    }

    /** Text comments and opaque ones, in the order they are written. */
    struct Comments {
        var text: [String]
        var opaque: [[UInt8]]
        var packet: [UInt8] { tagsPacket(text, opaque: opaque) }

        /** These comments with one TITLE of [title]: an undecodable TITLE cannot stay beside it. */
        func titled(_ title: String) -> Comments {
            Comments(text: withTitle(text, title), opaque: opaque.filter { !sameBytes(tagName($0), "TITLE") })
        }

        /// The recording instant wins. A legacy offset DATE remains useful when it differs from the
        /// source's pack stamp; copying that stamp after a fresh seal would instead invent a start.
        func dated(meeting: JSONObject, source: CassiniDocument?) -> Comments {
            let previous = text.first { sameBytes(tagName($0), "DATE") }.map { String($0.dropFirst(5)) }
            let sourceCreated = source?.manifest?["meeting"]?.object?["createdAtUtc"]?.string.flatMap(parseInstant)
            let legacy = previous.flatMap { value -> String? in
                guard let source, source.state != .staleAudio, let date = parseInstant(value), date != sourceCreated else { return nil }
                return value
            }
            let recorded = meeting["recordedAtUtc"]?.string.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasSuffix("Z"), parseInstant(trimmed) != nil else { return nil }
                return value
            }
            let date = recorded ?? legacy ?? meeting["createdAtUtc"]?.string
            guard let date else { return self }
            // DATE is ordinary metadata, so do not add it to the set of load-bearing derived tags.
            // Replace all spellings here, including opaque entries, just as TITLE does.
            let replacement = "DATE=\(date)"
            var replaced = false
            var result = text.compactMap { comment -> String? in
                guard sameBytes(tagName(comment), "DATE") else { return comment }
                guard !replaced else { return nil }
                replaced = true
                return replacement
            }
            if !replaced { result.append(replacement) }
            return Comments(text: result, opaque: opaque.filter { !sameBytes(tagName($0), "DATE") })
        }

        /**
         * These comments with every derived tag (see [isDerived]) replaced by its spelling in [fresh]: where the first
         * one of a name stands, so a rewrite moves nothing it keeps. Derived tags [fresh] has no value for are dropped,
         * and the rest of [fresh] follows in its own order.
         */
        func deriving(_ fresh: [String]) -> Comments {
            // Keyed by bytes: Swift's `==` would let a foreign name spelled with, say, KELVIN SIGN stand for a derived one.
            var pending = Dictionary(fresh.map { (Array(tagName($0).utf8), $0) }, uniquingKeysWith: { first, _ in first })
            var out: [String] = []
            for comment in text {
                let name = tagName(comment)
                guard isDerived(name) else { out.append(comment); continue }
                if let replacement = pending.removeValue(forKey: Array(name.utf8)) { out.append(replacement) }
            }
            out += fresh.filter { pending[Array(tagName($0).utf8)] != nil }
            return Comments(text: out, opaque: opaque)
        }
    }
}
