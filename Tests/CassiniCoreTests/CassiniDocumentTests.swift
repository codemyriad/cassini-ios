@testable import CassiniCore
import Foundation
import Testing

private func relabelled(_ data: [UInt8], _ labels: [String: String]) throws -> (CassiniDocument, CassiniDocument) {
    try withTemporaryDirectory { dir in
        let source = dir.appendingPathComponent("a.opus")
        try Data(data).write(to: source)
        let before = CassiniDocument.read(source)
        return (before, try CassiniDocument.relabel(source, existing: before, labels: labels, target: dir.appendingPathComponent("b.opus")))
    }
}

/**
 * [data] with its manifest replaced by [edit]'s result and its tags by [tags]: a writer's mistake made on purpose.
 * The manifest tags are re-encoded; nothing is verified.
 */
private func rewritten(_ data: [UInt8], tags: ([String]) -> [String] = { $0 }, manifest edit: (inout JSONObject) throws -> Void) throws -> [UInt8] {
    let document = CassiniDocument.read(data)
    var manifest = try #require(document.manifest)
    try edit(&manifest)
    let manifestTags = try CassiniPayload.encode(prefix: "CASSINI_PAYLOAD_", mime: CassiniPayload.mime, text: manifest.serialized()).tags
    let manifestNames = Set(manifestTags.map { CassiniDocument.tagName($0) })
    let kept = tags(document.comments.filter { !manifestNames.contains(CassiniDocument.tagName($0)) })
    let out = ArraySink()
    try OggOpus.rewrite(ArraySource(data), tags: CassiniDocument.tagsPacket(kept + manifestTags), to: out)
    return out.bytes
}

@Suite struct CassiniDocumentTests {
    let transcript = Transcript([Word("spk_1", 0, 20, "Hello")], language: "it")

    // ports: CassiniDocumentTest#retiredAsrProvenanceSurvivesAnInt8Retranscription
    @Test func retiredAsrProvenanceSurvivesAnInt8Retranscription() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Prima.")], language: "it")
        let provenance = JSONObject([("model", .string("nvidia/parakeet-tdt-0.6b-v3 FP32")),
                                     ("x-segmentation", .string("live 5 s steps with 1 s recorded overlap"))])
        let first = try CassiniDocument.create(silence(), transcript: transcript, title: "Old live note", processing: provenance)
        let original = CassiniDocument.read(first)
        var retranscribed = transcript
        retranscribed.words = [Word("spk_1", 0, 20, "Dopo.")]
        let nextBytes = try CassiniDocument.create(first, transcript: retranscribed, title: "Ignored",
                                                   processing: JSONObject([("model", .string("nvidia/parakeet-tdt-0.6b-v3 INT8"))]), existing: original)
        let next = CassiniDocument.read(nextBytes)
        #expect(next.state == .ok)
        #expect(next.variants.count == 2)
        #expect(original.variants[0].body == next.variants[0].body)
        let path: (CassiniDocument) -> JSON? = { $0.manifest?["provenance"]?.object?["speechToText"]?.object?[original.variants[0].id] }
        #expect(path(original)?.serialized() == path(next)?.serialized())
        #expect(try OggOpus.read(first).digest() == OggOpus.read(nextBytes).digest())
    }

    // ports: CassiniDocumentTest#newDocumentSealsAudioAndAppendedVariantPreservesExtensions
    @Test func newDocumentSealsAudioAndAppendedVariantPreservesExtensions() throws {
        let first = try CassiniDocument.create(silence(), transcript: transcript, title: "Italian sample", processing: JSONObject([("engine", .string("sherpa-onnx"))]))
        let original = CassiniDocument.read(first)
        #expect(original.state == .ok)
        #expect(original.selected()?.transcript == transcript)
        #expect(original.comments.contains("X_CUSTOM=keep=me"))
        var withPrivate = original
        withPrivate.comments += ["CASSINI_AUDIO_FUTURE=keep", "CASSINI_PAYLOAD_FUTURE=keep"]
        withPrivate.manifest!["extension"] = .object(JSONObject([("keep", .bool(true))]))
        var speakers = withPrivate.manifest!["speakers"]!.array!
        var speaker = speakers[0].object!; speaker["pronouns"] = .string("they"); speakers[0] = .object(speaker)
        withPrivate.manifest!["speakers"] = .array(speakers)
        var english = transcript; english.language = "en"
        let next = CassiniDocument.read(try CassiniDocument.create(first, transcript: english, title: "Ignored", processing: JSONObject(), existing: withPrivate))
        #expect(next.state == .ok)
        #expect(next.variants.count == 2)
        #expect(next.comments.contains("CASSINI_AUDIO_FUTURE=keep"))
        #expect(next.comments.contains("CASSINI_PAYLOAD_FUTURE=keep"))
        #expect(next.manifest?["extension"]?.object?["keep"] == .bool(true))
        #expect(next.manifest?["speakers"]?.array?[0].object?["pronouns"] == .string("they"))
        #expect(original.variants[0].body == next.variants[0].body)
        let again = try CassiniDocument.create(first, transcript: transcript, title: "Again", processing: JSONObject(), existing: original)
        #expect(try OggOpus.read(first).digest() == OggOpus.read(again).digest())
    }

    // ports: CassiniDocumentTest#relabelChangesOnlyTheLabels
    @Test func relabelChangesOnlyTheLabels() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Hello"), Word("spk_2", 20, 40, "Hi")], language: "it")
        let first = try CassiniDocument.create(silence(), transcript: transcript, title: "Two", processing: JSONObject([("engine", .string("sherpa-onnx"))]))
        var base = CassiniDocument.read(first)
        base.manifest!["x"] = .object(JSONObject([("keep", .bool(true))]))
        var speakers = base.manifest!["speakers"]!.array!
        var speaker = speakers[0].object!; speaker["pronouns"] = .string("she"); speakers[0] = .object(speaker)
        base.manifest!["speakers"] = .array(speakers)
        let (before, after) = try relabelled(try CassiniDocument.create(first, transcript: transcript, title: "Ignored", processing: JSONObject(), existing: base),
                                             ["spk_1": "  Anna "])
        #expect(after.state == .ok)
        #expect(after.warnings.isEmpty)
        #expect(after.speakerLabel("spk_1") == "Anna")
        #expect(after.speakerLabel("spk_2") == "spk_2")
        #expect(after.manifest?["speakers"]?.array?[0].object?["pronouns"] == .string("she"))
        #expect(after.manifest?["x"]?.object?["keep"] == .bool(true))
        #expect(before.manifest?["meeting"]?.serialized() == after.manifest?["meeting"]?.serialized())
        #expect(before.manifest?["integrity"]?.serialized() == after.manifest?["integrity"]?.serialized())
        #expect(before.variants.map { $0.id } == after.variants.map { $0.id })
        #expect(before.variants.map { $0.body } == after.variants.map { $0.body })
        #expect(comments(before) { !$0.hasPrefix("CASSINI_PAYLOAD_") } == comments(after) { !$0.hasPrefix("CASSINI_PAYLOAD_") })
        let fixed: (String) -> Bool = { $0 == "CASSINI_PAYLOAD_SCHEMA" || $0 == "CASSINI_PAYLOAD_MIME" }
        #expect(comments(before, named: fixed) == comments(after, named: fixed))
        #expect(comments(before) { $0 == "CASSINI_PAYLOAD_SHA256" } != comments(after) { $0 == "CASSINI_PAYLOAD_SHA256" })
        #expect(comments(before) { $0 == "CASSINI_PAYLOAD_RAW_BYTES" } != comments(after) { $0 == "CASSINI_PAYLOAD_RAW_BYTES" })
        var expected = before.manifest!
        var renamed = expected["speakers"]!.array!
        var first0 = renamed[0].object!
        first0["label"] = .string("Anna")
        first0["provenance"] = .string("user")
        renamed[0] = .object(first0)
        expected["speakers"] = .array(renamed)
        #expect(expected.serialized() == after.manifest?.serialized())
    }

    // ports: CassiniDocumentTest#relabelRejectsUnknownSpeakersAndBlankLabels
    @Test(arguments: [["spk_9": "Anna"], ["spk_1": "  "]])
    func relabelRejectsUnknownSpeakersAndBlankLabels(labels: [String: String]) throws {
        let data = try CassiniDocument.create(silence(), transcript: transcript, title: "One", processing: JSONObject())
        #expect(throws: CassiniError.self) { try relabelled(data, labels) }
    }

    // ports: CassiniDocumentTest#relabelConformanceVectorWithUnknownMembers
    @Test(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
    func relabelConformanceVectorWithUnknownMembers() throws {
        let (before, after) = try relabelled(try Conformance.vector("014-unknown-manifest-member"), ["spk_a": "Anna"])
        #expect(after.state == .ok)
        #expect(after.speakerLabel("spk_a") == "Anna")
        #expect(before.speakerLabel("spk_b") == after.speakerLabel("spk_b"))
        #expect(after.manifest!.has("cassiniFutureField"))
        #expect(before.manifest?["speakers"]?.array?[0].object?["pronouns"] == after.manifest?["speakers"]?.array?[0].object?["pronouns"])
        #expect(before.variants.map { $0.body } == after.variants.map { $0.body })
        #expect(before.manifest?["integrity"]?.object?["opusAudioSha256"] == after.manifest?["integrity"]?.object?["opusAudioSha256"])
    }

    // ports: CassiniDocumentTest#truncatedAudioKeepsReadableMetadata
    @Test func truncatedAudioKeepsReadableMetadata() throws {
        let data = try CassiniDocument.create(silence(), transcript: Transcript([]), title: "Truncated", processing: JSONObject())
        let document = CassiniDocument.read(Array(data.dropLast()))
        #expect(document.state == .unverified)
        #expect(document.selected()?.transcript != nil)
    }

    // ports: CassiniDocumentTest#crcFailureKeepsTranscriptButDoesNotVerifyAudio
    @Test func crcFailureKeepsTranscriptButDoesNotVerifyAudio() throws {
        var data = try CassiniDocument.create(silence(), transcript: Transcript([]), title: "CRC", processing: JSONObject())
        data[22] ^= 1
        let document = CassiniDocument.read(data)
        #expect(document.state == .unverified)
        #expect(document.selected()?.transcript != nil)
    }

    @Test func tokensBecomeWordsWithoutStretchingOverPunctuation() throws {
        let words = try Transcript.timedWordsFromTokens(["▁Hello", ",", "▁how", "▁goes", "?"],
                                                        timestamps: [0.0, 0.9, 1.0, 1.4, 2.0], durations: [0.4, 0.0, 0.3, 0.2, 0.08])
        #expect(words.map { $0.word } == [Word("spk_1", 0, 400, "Hello,"), Word("spk_1", 1000, 1300, "how"), Word("spk_1", 1400, 1600, "goes?")])
        #expect(words.map { $0.capMs } == [900, 1300, 2080])
    }
}

/** Only the digest copy blocks verification; every other disagreement between a tag and the manifest only warns. */
@Suite(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
struct VerificationGateTests {
    @Test(arguments: [("007-chunk-count-too-high", "CASSINI_TX_RAW_ASR_PAYLOAD_CHUNK_COUNT"),
                      ("017-dangling-transcript-id", "CASSINI_TRANSCRIPT_IDS")])
    func aStaleConvenienceTagStillVerifies(vector: String, tag: String) throws {
        let document = CassiniDocument.read(try Conformance.vector(vector))
        #expect(document.state == .ok)
        #expect(document.warnings.contains("tag-manifest-disagreement: \(tag)"))
        #expect(document.selected()?.transcript != nil)
    }

    @Test func aDisagreeingDigestCopyLeavesTheAudioUnverified() throws {
        let document = CassiniDocument.read(try Conformance.vector("011-tag-manifest-disagreement"))
        #expect(document.state == .unverified)
        #expect(document.warnings == ["tag-manifest-disagreement: CASSINI_AUDIO_OPUS_SHA256"])
    }

    @Test func staleAudioSaysWhatDiffers() throws {
        let document = CassiniDocument.read(try Conformance.vector("010-stale-audio"))
        #expect(document.state == .staleAudio)
        #expect(document.warnings.contains("audio-digest-mismatch"))
        #expect(document.warnings.contains("audio-shape-mismatch"))
    }

    /** Re-sealing a source without a verified manifest must not keep its chunk sets: vector 010's words prefix repeats. */
    @Test(arguments: ["010-stale-audio", "015-unknown-major-version"])
    func aFreshSealDropsEveryCassiniTagOfTheSource(vector: String) throws {
        let source = try Conformance.vector(vector)
        let foreign = CassiniDocument.read(source).comments.filter { !CassiniDocument.tagName($0).hasPrefix("CASSINI_") }
        let transcript = Transcript([Word("spk_1", 0, 20, "Hello")])
        let sealed = CassiniDocument.read(try CassiniDocument.create(source, transcript: transcript, title: "Resealed", processing: JSONObject()))
        #expect(sealed.state == .ok)
        #expect(sealed.variants.map { $0.id } == ["words"])
        #expect(sealed.selected()?.transcript == transcript)
        #expect(sealed.title == "Resealed")
        #expect(comments(sealed) { $0.hasPrefix("CASSINI_TX_") && !$0.hasPrefix("CASSINI_TX_WORDS_PAYLOAD_") }.isEmpty)
        let ordinary = { (comment: String) in
            let name = CassiniDocument.tagName(comment)
            return !name.hasPrefix("CASSINI_") && name != "TITLE" && name != "DATE"
        }
        #expect(sealed.comments.filter(ordinary) == foreign.filter(ordinary))
        let created = try #require(sealed.manifest?["meeting"]?.object?["createdAtUtc"]?.string)
        #expect(comments(sealed) { CassiniDocument.tagName($0) == "DATE" } == ["DATE=\(created)"])
        #expect(sealed.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
    }
}

@Suite struct CommentDecodingTests {
    let latin1Title = Array("TITLE=Caf".utf8) + [0xE9]
    let latin1Artist = Array("ARTIST=Ren".utf8) + [0xE9, 0x65]

    @Test func aForeignCommentThatIsNotUtf8IsSkippedWithAWarning() throws {
        let document = CassiniDocument.read(try silence(["X_CUSTOM=keep=me"], opaque: [latin1Title]))
        #expect(document.state == .plainAudio)
        #expect(document.comments == ["X_CUSTOM=keep=me"])
        #expect(document.opaqueComments == [latin1Title])
        #expect(document.warnings == ["non-utf8-comment: TITLE"])
    }

    @Test func aSealCarriesForeignBytesForwardAndReplacesAnUndecodableTitle() throws {
        let sealed = try CassiniDocument.create(silence(["X_CUSTOM=keep=me"], opaque: [latin1Title, latin1Artist]),
                                                transcript: Transcript([Word("spk_1", 0, 20, "Hello")]), title: "Meeting", processing: JSONObject())
        let document = CassiniDocument.read(sealed)
        #expect(document.state == .ok)
        #expect(document.opaqueComments == [latin1Artist])
        #expect(comments(document) { $0 == "TITLE" } == ["TITLE=Meeting"])
        #expect(document.comments.contains("X_CUSTOM=keep=me"))
    }

    @Test func aCassiniCommentThatIsNotUtf8MakesTheMetadataInvalid() throws {
        let document = CassiniDocument.read(try silence([], opaque: [Array("CASSINI_FORMAT=org.cassini.portable-meeting/1".utf8) + [0xE9]]))
        #expect(document.state == .invalidMetadata)
    }

    @Test func tagNamesFoldAsciiCaseOnly() throws {
        // "ſ" upper-cases to "S" in Unicode, but a tag name is ASCII: this is not CASSINI_FORMAT.
        let document = CassiniDocument.read(try silence(["caſſini_format=org.cassini.portable-meeting/1"]))
        #expect(document.state == .plainAudio)
        #expect(CassiniDocument.tagName("cassini_Format=x") == "CASSINI_FORMAT")
        #expect(CassiniDocument.tagName("caſſini_format=x") == "CAſſINI_FORMAT")
    }
}

@Suite struct SealTitleTests {
    @Test func aSealWritesTheManifestTitleIntoTheTitleTag() throws {
        let first = try CassiniDocument.create(silence(["TITLE=voice-memo", "X_CUSTOM=keep=me"]), transcript: Transcript([Word("spk_1", 0, 20, "Hello")]),
                                               title: "  Call with Luca \n", processing: JSONObject())
        let original = CassiniDocument.read(first)
        #expect(original.title == "Call with Luca")
        #expect(Array(original.comments.prefix(2)) == ["TITLE=Call with Luca", "X_CUSTOM=keep=me"])
        // A rename made in the manifest reaches the tag when a variant is added.
        var renamed = original
        var meeting = try #require(renamed.manifest?["meeting"]?.object)
        meeting["title"] = .string("Standup")
        renamed.manifest!["meeting"] = .object(meeting)
        let next = CassiniDocument.read(try CassiniDocument.create(first, transcript: Transcript([Word("spk_1", 0, 20, "Hi")]),
                                                                   title: "Ignored", processing: JSONObject(), existing: renamed))
        #expect(next.state == .ok)
        #expect(comments(next) { $0 == "TITLE" } == ["TITLE=Standup"])
    }

    @Test func theWordBodyIsCompactAndTheDescriptorOmitsAnUnknownLanguage() throws {
        let document = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: Transcript([Word("spk_1", 0, 20, "Hello")]),
                                                                       title: "Compact", processing: JSONObject()))
        let body = try #require(document.selected()?.body)
        #expect(!body.contains("\n") && !body.contains(" "))
        #expect(document.selected()?.descriptor.has("language") == false)
    }
}

@Suite struct TranscriptMediaTypeTests {
    /** The words format decides whether a body can be read; a different media type is only a warning. */
    @Test func anUnexpectedMimeIsAWarningNotAnUnavailableTranscript() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Hello")])
        let source = try CassiniDocument.create(silence(), transcript: transcript, title: "Hint", processing: JSONObject())
        let data = try rewritten(source, tags: { tags in
            tags.map { CassiniDocument.tagName($0) == "CASSINI_TX_WORDS_PAYLOAD_MIME" ? "CASSINI_TX_WORDS_PAYLOAD_MIME=application/json" : $0 }
        }) { manifest in
            var transcripts = try manifest.array("transcripts")
            var descriptor = try #require(transcripts[0].object)
            var ref = try descriptor.object("payloadRef")
            ref["mime"] = .string("application/json")
            descriptor["payloadRef"] = .object(ref)
            transcripts[0] = .object(descriptor)
            manifest["transcripts"] = .array(transcripts)
        }
        let document = CassiniDocument.read(data)
        #expect(document.state == .ok)
        #expect(document.selected()?.transcript == transcript)
        #expect(document.warnings == ["transcript-mime-mismatch: words"])
    }
}
