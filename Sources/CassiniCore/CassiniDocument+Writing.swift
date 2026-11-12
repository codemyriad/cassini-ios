import Foundation

/** Writing a document: a new seal over the audio, and relabel and retitle, which rewrite only the manifest. */
extension CassiniDocument {
    /**
     * Adds a variant while retaining existing descriptors, bodies, extensions and unrelated tags. Without [existing],
     * a fresh seal carries [source]'s private and unknown manifest members, its meeting id and its meeting and
     * provenance members not tied to its transcripts; see [seal]. `recordedAt` is the trustworthy instant at
     * playback position zero. It fills an absent recordedAtUtc on fresh, existing or carried manifests; an existing
     * UTC start over matching audio is never overwritten; a stale source’s UTC/local fields are discarded first. An unknown start stays absent, and no local recording-site label is inferred
     * from the machine clock.
     */
    public static func create(_ audioBytes: [UInt8], transcript: Transcript, title: String, processing: JSONObject,
                              existing: CassiniDocument? = nil, speakerLabels: [String: String] = [:],
                              speakerHints: [String: JSONObject] = [:],
                              carrying source: CassiniDocument? = nil, recordedAt: Date? = nil) throws -> [UInt8] {
        let (comments, digest) = try seal(OggOpus.scan(ArraySource(audioBytes)), transcript, title, processing, existing, speakerLabels, source, recordedAt, speakerHints)
        let out = ArraySink()
        try check(try OggOpus.rewrite(ArraySource(audioBytes), tags: comments.packet, to: out).digest() == digest, "Audio changed while sealing")
        try verify(read(out.bytes), transcript)
        return out.bytes
    }

    /** Streams [audio] into [target] behind the new tags and verifies the written file from disk; nothing is left on failure. */
    @discardableResult
    public static func create(_ audio: URL, transcript: Transcript, title: String, processing: JSONObject, existing: CassiniDocument?,
                              speakerLabels: [String: String], speakerHints: [String: JSONObject] = [:],
                              carrying source: CassiniDocument? = nil, recordedAt: Date? = nil,
                              target: URL) throws -> CassiniDocument {
        let (comments, digest) = try seal(OggOpus.scan(audio), transcript, title, processing, existing, speakerLabels, source, recordedAt, speakerHints)
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
    static func writeWithTags(_ source: URL, _ comments: Comments, _ digest: String, _ target: URL) throws {
        try check(try OggOpus.rewrite(source, tags: comments.packet, to: target).digest() == digest, "Audio changed while sealing")
    }

    /**
     * Renames speakers only: bodies, variants, unknown members and unrelated tags stay as they are, and the
     * manifest and every copy of it are written afresh. The written file must read back identical apart from those
     * labels.
     */
    @discardableResult
    public static func relabel(_ source: URL, existing: CassiniDocument, labels: [String: String], target: URL) throws -> CassiniDocument {
        guard existing.state == .ok, var manifest = existing.manifest else { throw CassiniError("Only a verified document can be relabelled") }
        var speakers = try manifest.array("speakers")
        for (id, label) in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try check(!trimmed.isEmpty, "Blank label")
            guard let i = speakers.firstIndex(where: { sameBytes($0.object?["id"]?.string, id) }), var speaker = speakers[i].object else {
                throw CassiniError("Unknown speaker \(id)")
            }
            speaker["label"] = .string(trimmed)
            speakers[i] = .object(speaker)
        }
        manifest["speakers"] = .array(speakers)
        return try rewriteManifest(source, existing: existing, manifest: manifest, target: target)
    }

    /**
     * Renames the meeting only: sets `meeting.title` and the TITLE tag to the trimmed [title]. The first TITLE tag is
     * replaced where it stands, further ones are dropped, and one is added when there is none. Bodies, variants,
     * unknown members, unrelated tags and the audio stay as they are; the manifest and its copies are written afresh.
     * The written file must read back identical apart from the title.
     */
    @discardableResult
    public static func retitle(_ source: URL, existing: CassiniDocument, title: String, target: URL) throws -> CassiniDocument {
        guard existing.state == .ok, var manifest = existing.manifest else { throw CassiniError("Only a verified document can be retitled") }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(!clean.isEmpty, "Blank title")
        var meeting = try manifest.object("meeting")
        meeting["title"] = .string(clean)
        manifest["meeting"] = .object(meeting)
        return try rewriteManifest(source, existing: existing, manifest: manifest, title: clean, target: target)
    }

    /**
     * Writes [source]'s audio behind the comments of [existing] with every derived tag rebuilt from [manifest] (and
     * TITLE set to [title], when given), then reads the file back: it must verify, agree with its own tags and carry
     * exactly that manifest, those other comments and every variant body of [existing]. Nothing is left at [target] on
     * failure.
     */
    static func rewriteManifest(_ source: URL, existing: CassiniDocument, manifest input: JSONObject, title: String? = nil,
                                        target: URL) throws -> CassiniDocument {
        let manifest = try canonicalizingTimestamps(input)
        let digest = try manifest.object("integrity").string("opusAudioSha256")
        var kept = Comments(text: existing.comments, opaque: existing.opaqueComments)
        if let title { kept = kept.titled(title) }
        kept = kept.dated(meeting: try manifest.object("meeting"), source: existing)
        let comments = kept.deriving(try copies(of: manifest) + manifestTags(manifest))
        do {
            try writeWithTags(source, comments, digest, target)
            let written = read(target)
            try check(written.state == .ok && agreesWithManifest(written) && written.manifest == manifest, "Rewritten manifest does not read back")
            try check(written.variants.map { $0.id } == existing.variants.map { $0.id } &&
                      written.variants.map { $0.body } == existing.variants.map { $0.body }, "Rewritten transcripts do not read back")
            try check(written.comments == comments.text && written.opaqueComments == comments.opaque, "Rewritten tags do not read back")
            return written
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /** The top-level members the manifest schema defines. A fresh seal writes the ones it needs itself. */
    static let schemaMembers = ["kind", "version", "profile", "meeting", "audio", "integrity", "speakers", "transcripts",
                                "readableTranscripts", "provenance", "summary", "attachments"]

    /**
     * What a fresh seal carries from [source]'s manifest, verbatim and in its order: `x` (private data, SPEC "Private
     * use") and every other top-level member the schema does not define (SPEC: a rewrite carries unrecognised members
     * forward). Nothing for a source without a manifest.
     */
    public static func carriedMembers(of source: CassiniDocument?) -> [(key: String, value: JSON)] {
        (source?.manifest?.pairs ?? []).filter { pair in !schemaMembers.contains { sameBytes($0, pair.key) } }
    }

    /** The `meeting` members a fresh seal sets itself; every other member of the source's `meeting` is kept. */
    static let resealedMeetingMembers = ["title", "createdAtUtc", "durationMs"]

    /** The `provenance` members that describe the source's transcripts, summary and audio; a fresh seal keeps the rest. */
    static let sourceProvenanceMembers = ["speechToText", "displayTranscript", "meetingSummary", "attribution", "wordTimings"]

    /**
     * The `meeting` a fresh seal starts from: [source]'s, verbatim and in its order, when it has an id. A fresh seal
     * covers the same audio packets, so it is a tag rewrite and keeps the meeting's id (SPEC `meeting.id`) along with
     * every member this build does not know; it then sets [resealedMeetingMembers] itself. Recording-time metadata is
     * retained only while the source has not been shown to describe different audio (`staleAudio`).
     */
    public static func carriedMeeting(of source: CassiniDocument?) -> JSONObject? {
        guard var meeting = source?.manifest?["meeting"]?.object, meeting["id"]?.string?.isEmpty == false else { return nil }
        if source?.state == .staleAudio {
            meeting["recordedAtUtc"] = nil
            meeting["recordedAtLocal"] = nil
        }
        return meeting
    }

    /**
     * The members of [source]'s `provenance` a fresh seal keeps, verbatim and in their order: every one but
     * [sourceProvenanceMembers], which describe variants, a summary and word timing the seal does not carry.
     */
    public static func carriedProvenance(of source: CassiniDocument?) -> [(key: String, value: JSON)] {
        (source?.manifest?["provenance"]?.object?.pairs ?? []).filter { pair in
            !sourceProvenanceMembers.contains { sameBytes($0, pair.key) }
        }
    }

    static func verify(_ sealed: CassiniDocument, _ transcript: Transcript) throws {
        try check(sealed.state == .ok && agreesWithManifest(sealed) && sealed.selected()?.transcript == transcript,
                  "Sealed document does not read back")
    }

    /**
     * The comments and audio digest of [stream] with [transcript] added as the new default variant. Beside a verified
     * [existing] document its transcript chunks and foreign comments are kept and every tag derived from the manifest
     * is written afresh, so no stale copy survives. Without one no CASSINI_ tag of the source can be trusted to match
     * the new manifest, so all of them are dropped; foreign comments always survive. TITLE follows `meeting.title`.
     *
     * A fresh seal builds its manifest anew from what [source] holds that is not tied to its transcripts or audio
     * (SPEC "Extensibility": a rewrite carries unrecognised members forward). It appends [carriedMembers] unchanged,
     * the private `x` data and any top-level member a newer format defines; starts `meeting` from [carriedMeeting],
     * keeping its id; and starts `provenance` from [carriedProvenance]. That source is the unverified or stale document
     * being sealed afresh; its integrity, audio, speakers, transcripts, summary and their provenance describe audio
     * the new manifest does not, so none of them is carried. Beside [existing] the manifest is already that
     * document's, so [source] must be nil.
     */
    static func seal(_ stream: OggOpus.Info, _ transcript: Transcript, _ title: String, _ processing: JSONObject,
                     _ existing: CassiniDocument?, _ speakerLabels: [String: String],
                     _ source: CassiniDocument? = nil, _ recordedAt: Date? = nil,
                     _ speakerHints: [String: JSONObject] = [:]) throws -> (comments: Comments, digest: String) {
        let digest = try stream.digest()
        try check(existing == nil || existing!.state == .ok, "Never rebind stale transcripts to different audio")
        try check(existing == nil || source == nil, "A seal beside a document keeps its manifest; it carries nothing else")
        let now = now()
        let shape: [(String, JSON)] = [("sampleRate", .int(48000)), ("channels", .int(stream.channels)),
                                       ("sampleCount", .int(stream.sampleCount)), ("durationMs", .int(stream.durationMs))]
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var meeting = carriedMeeting(of: source) ?? JSONObject([("id", .string("mtg_" + UUID().uuidString.lowercased()))])
        meeting["title"] = .string(trimmedTitle.isEmpty ? "Recording" : trimmedTitle)
        meeting["createdAtUtc"] = .string(now)
        meeting["durationMs"] = .int(stream.durationMs)
        var manifest = existing?.manifest ?? JSONObject([
            ("kind", .string("cassini-portable-meeting")), ("version", .int(1)), ("profile", .string("ogg-opus")),
            ("meeting", .object(meeting)),
            ("audio", .object(JSONObject([("container", .string("ogg")), ("codec", .string("opus")), ("sampleRate", .int(48000)),
                                          ("channels", .int(stream.channels)), ("sampleCount", .int(stream.sampleCount)),
                                          ("durationMs", .int(stream.durationMs))]))),
            ("integrity", .object(JSONObject([("matchPolicy", .string(matchPolicy)), ("opusAudioSha256", .string(digest))] + shape))),
            ("speakers", .array([])), ("transcripts", .array([])),
        ])
        manifest = try canonicalizingTimestamps(manifest)
        // A caller's trustworthy start can repair a legacy own document without rebinding its
        // meeting id or audio. An existing UTC start stays authoritative while its source audio still matches.
        if let recordedAt, var recordedMeeting = manifest["meeting"]?.object,
           recordedMeeting["recordedAtUtc"] == nil {
            recordedMeeting["recordedAtUtc"] = .string(instantText(recordedAt))
            manifest["meeting"] = .object(recordedMeeting)
        }
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
        var known = Set(speakers.compactMap { $0.object?["id"]?.string.map { Array($0.utf8) } })
        for word in transcript.words where known.insert(Array(word.speaker.utf8)).inserted {
            let label = speakerLabels.first { sameBytes($0.key, word.speaker) }?.value ?? word.speaker
            speakers.append(.object(JSONObject([("id", .string(word.speaker)), ("label", .string(label))])))
        }
        // The portable speaker object is open: these optional display hints never alter identity or labels.
        manifest["speakers"] = .array(speakers.map { entry in
            guard var speaker = entry.object, let id = speaker["id"]?.string, let hints = speakerHints[id] else { return entry }
            for key in ["colourIndex", "provenance"] {
                if let value = hints[key] { speaker[key] = value }
            }
            return .object(speaker)
        })
        var provenance = manifest["provenance"]?.object ?? JSONObject(carriedProvenance(of: source).map { ($0.key, $0.value) })
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
        if existing == nil { for (key, value) in carriedMembers(of: source) { manifest[key] = value } }
        var comments: Comments
        if let existing {
            // A verified document's transcript chunks stay; every copy of its manifest is rebuilt from the new one.
            comments = Comments(text: existing.comments.filter { !hasBytePrefix(tagName($0), prefix) }, opaque: existing.opaqueComments)
        } else {
            let foreign = try foreignComments(stream.tags)
            comments = Comments(text: foreign.text, opaque: foreign.opaque)
        }
        comments = comments.titled(try manifest.object("meeting").string("title"))
        comments = comments.dated(meeting: try manifest.object("meeting"), source: existing ?? source)
        comments = comments.deriving(try copies(of: manifest) + bodyTags.filter { !isDerived(tagName($0)) } + manifestTags(manifest))
        return (comments, digest)
    }
}
