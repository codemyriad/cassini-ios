@testable import CassiniCore
import Foundation
import Testing

/**
 * A fresh seal over an unverified or stale document keeps the manifest's private `x` data (desktop notes under
 * `x["gocassini.com"].notes`) and any top-level member a newer format defines, verbatim: SPEC "Private use" and "a
 * rewrite carries unrecognised members forward". It keeps the meeting (its id, `recordedAtLocal` and unknown members)
 * and the provenance members not tied to a transcript too. Nothing that describes the source's transcripts or audio
 * survives, since that is other audio or audio nobody checked.
 */
@Suite struct CassiniDocumentCarryTests {
    /** Desktop notes in their own order with a member this build does not know, a foreign domain and an integer above 2^53. */
    static let privateText = #"{"gocassini.com":{"notes":[{"atMs":1200,"text":"Budget next week","futureNoteField":{"keep":[1,2.50]}},"#
        + #"{"atMs":800,"text":"Listed second, said first"}]},"example.com":{"ticket":"OPS-14","count":9007199254740993}}"#
    static let futureText = #"{"since":"v1.4","flags":[true,null]}"#
    static let futureMeetingText = #"{"room":"Sala 2","seats":9007199254740993}"#

    let words = Transcript([Word("spk_1", 0, 20, "Hello")], language: "it")
    let fresh = Transcript([Word("spk_9", 0, 20, "Hi")], language: "it")

    /** A verified document over [silence] with two variants, `x` and a member no schema defines. */
    func documentWithPrivateData() throws -> [UInt8] {
        let first = try CassiniDocument.create(silence(), transcript: words, title: "Notes",
                                               processing: JSONObject([("engine", .string("gocassini"))]))
        var base = CassiniDocument.read(first)
        base.manifest!["x"] = .object(try JSON.parseObject(Self.privateText))
        base.manifest!["cassiniFutureField"] = .object(try JSON.parseObject(Self.futureText))
        var meeting = try base.manifest!.object("meeting")
        meeting["recordedAtLocal"] = .string("2026-10-30T09:15:00")
        meeting["futureMeetingField"] = .object(try JSON.parseObject(Self.futureMeetingText))
        base.manifest!["meeting"] = .object(meeting)
        var provenance = try base.manifest!.object("provenance")
        provenance["futureProvenanceField"] = .object(try JSON.parseObject(Self.futureText))
        base.manifest!["provenance"] = .object(provenance)
        return try CassiniDocument.create(first, transcript: words, title: "Notes", processing: JSONObject(), existing: base)
    }

    /** [document]'s tags over two packets of other audio: the stale twin of [document]. */
    func staleTwin(_ document: [UInt8]) throws -> [UInt8] {
        let other = OggOpus.Stream(head: opusHead, tags: CassiniDocument.tagsPacket([]), audio: [[0xF8, 0xFF, 0xFE], [0xF8, 0xFF, 0xFE]],
                                   finalGranule: 1920, validFraming: true)
        return try OggOpus.mux(other, tags: OggOpus.read(document).tags)
    }

    /** [document] with its audio digest copy contradicting the manifest, so the audio cannot be verified. */
    func unverifiedTwin(_ document: [UInt8]) throws -> [UInt8] {
        let tags = CassiniDocument.read(document).comments.map { comment in
            CassiniDocument.tagName(comment) == "CASSINI_AUDIO_OPUS_SHA256" ? "CASSINI_AUDIO_OPUS_SHA256=" + String(repeating: "0", count: 64) : comment
        }
        return try OggOpus.mux(OggOpus.read(document), tags: CassiniDocument.tagsPacket(tags))
    }

    /** Seals [fresh] afresh over [source]'s audio, carrying [source]. */
    func resealed(_ source: [UInt8]) throws -> CassiniDocument {
        CassiniDocument.read(try CassiniDocument.create(source, transcript: fresh, title: "Resealed", processing: JSONObject(),
                                                        carrying: CassiniDocument.read(source)))
    }

    func assertCarried(from source: [UInt8], state: DocumentState, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let before = CassiniDocument.read(source)
        try #require(before.state == state, sourceLocation: sourceLocation)
        let sealed = try resealed(source)
        #expect(sealed.state == .ok, sourceLocation: sourceLocation)
        #expect(sealed.manifest?["x"]?.serialized() == before.manifest?["x"]?.serialized(), sourceLocation: sourceLocation)
        #expect(sealed.manifest?["x"]?.serialized() == JSON.object(try JSON.parseObject(Self.privateText)).serialized(),
                sourceLocation: sourceLocation)
        #expect(sealed.manifest?["x"]?.serialized().contains("9007199254740993") == true, sourceLocation: sourceLocation)
        #expect(sealed.manifest?["cassiniFutureField"]?.serialized() == before.manifest?["cassiniFutureField"]?.serialized(),
                sourceLocation: sourceLocation)
        #expect(sealed.variants.map(\.id) == ["words"], sourceLocation: sourceLocation)
        #expect(sealed.selected()?.transcript == fresh, sourceLocation: sourceLocation)
        #expect(comments(sealed) { $0.hasPrefix("CASSINI_TX_") && !$0.hasPrefix("CASSINI_TX_WORDS_PAYLOAD_") }.isEmpty,
                sourceLocation: sourceLocation)
        #expect(sealed.manifest?["provenance"]?.object?["speechToText"]?.object?.keys == ["words"], sourceLocation: sourceLocation)
        #expect(sealed.manifest?["integrity"]?.object?["opusAudioSha256"] == .string(try OggOpus.read(source).digest()),
                sourceLocation: sourceLocation)
        let meeting = sealed.manifest?["meeting"]?.object, sourceMeeting = before.manifest?["meeting"]?.object
        #expect(meeting?["id"] == sourceMeeting?["id"], "the same packets keep the meeting", sourceLocation: sourceLocation)
        #expect(meeting?.keys == sourceMeeting?.keys, sourceLocation: sourceLocation)
        #expect(meeting?["recordedAtLocal"] == .string("2026-10-30T09:15:00"), sourceLocation: sourceLocation)
        #expect(meeting?["futureMeetingField"]?.serialized() == #"{"room":"Sala 2","seats":9007199254740993}"#,
                sourceLocation: sourceLocation)
        #expect(meeting?["title"] == .string("Resealed"), sourceLocation: sourceLocation)
        #expect(meeting?["durationMs"] == sealed.manifest?["audio"]?.object?["durationMs"], sourceLocation: sourceLocation)
        #expect(sealed.comments.contains("CASSINI_RECORDED_AT_LOCAL=2026-10-30T09:15:00"), sourceLocation: sourceLocation)
        let provenance = sealed.manifest?["provenance"]?.object
        #expect(provenance?["futureProvenanceField"]?.serialized() == JSON.object(try JSON.parseObject(Self.futureText)).serialized(),
                sourceLocation: sourceLocation)
        #expect(provenance?["speechToText"]?.object?["words"] == .object(JSONObject()), sourceLocation: sourceLocation)
        #expect(sealed.comments.contains("X_CUSTOM=keep=me"), sourceLocation: sourceLocation)
    }

    @Test func aFreshSealCarriesThePrivateMemberOfAStaleSource() throws {
        let stale = try staleTwin(documentWithPrivateData())
        try assertCarried(from: stale, state: .staleAudio)
        #expect(try resealed(stale).manifest?["integrity"]?.object?["opusAudioSha256"]
                != CassiniDocument.read(stale).manifest?["integrity"]?.object?["opusAudioSha256"])
    }

    @Test func aFreshSealCarriesThePrivateMemberOfAnUnverifiedSource() throws {
        try assertCarried(from: try unverifiedTwin(documentWithPrivateData()), state: .unverified)
    }

    /** Only `x` and members outside the schema travel; whatever the schema defines describes the old audio. */
    @Test func aFreshSealCarriesNothingTheSchemaDefines() throws {
        var manifest = try #require(CassiniDocument.read(try documentWithPrivateData()).manifest)
        manifest["summary"] = .object(JSONObject([("text", .string("Old summary"))]))
        manifest["attachments"] = .array([.object(JSONObject([("name", .string("slides.pdf"))]))])
        manifest["readableTranscripts"] = .array([.object(JSONObject([("id", .string("readable"))]))])
        var provenance = try manifest.object("provenance")
        provenance["displayTranscript"] = .object(JSONObject([("words", .object(JSONObject()))]))
        provenance["meetingSummary"] = .object(JSONObject([("engine", .string("summariser"))]))
        provenance["wordTimings"] = .object(JSONObject([("endsBoundedByAudio", .bool(true))]))
        manifest["provenance"] = .object(provenance)
        let source = CassiniDocument(state: .staleAudio, manifest: manifest)

        #expect(CassiniDocument.carriedMembers(of: source).map(\.key) == ["x", "cassiniFutureField"])
        #expect(CassiniDocument.carriedProvenance(of: source).map(\.key) == ["futureProvenanceField"])
        let sealed = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: fresh, title: "Resealed",
                                                                     processing: JSONObject(), carrying: source))
        #expect(sealed.state == .ok)
        #expect(sealed.manifest?.keys.suffix(2) == ["x", "cassiniFutureField"])
        for key in ["summary", "attachments", "readableTranscripts"] { #expect(sealed.manifest?.has(key) == false, "\(key)") }
        for key in ["displayTranscript", "meetingSummary", "wordTimings"] {
            #expect(sealed.manifest?["provenance"]?.object?.has(key) == false, "\(key)")
        }
        #expect(sealed.manifest?["provenance"]?.object?["attribution"]?.object?["mode"] == .string("single-source"))
        #expect(sealed.manifest?["speakers"]?.array?.compactMap { $0.object?["id"]?.string } == ["spk_9"])
        #expect(sealed.manifest?["meeting"]?.object?["title"] == .string("Resealed"))
    }

    @Test func aFreshSealWithoutAManifestWritesNoX() throws {
        let plain = try silence()
        let sealed = CassiniDocument.read(try CassiniDocument.create(plain, transcript: fresh, title: "Plain", processing: JSONObject(),
                                                                     carrying: CassiniDocument.read(plain)))
        #expect(sealed.state == .ok)
        #expect(sealed.manifest?.has("x") == false)
        #expect(CassiniDocument.carriedMembers(of: CassiniDocument(state: .invalidMetadata)).isEmpty)
        #expect(CassiniDocument.carriedMembers(of: nil).isEmpty)
        #expect(CassiniDocument.carriedMeeting(of: nil) == nil)
        #expect(CassiniDocument.carriedProvenance(of: nil).isEmpty)
    }

    @Test(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
    func aNewerFormatHasNoManifestToCarry() throws {
        let source = try Conformance.vector("015-unknown-major-version")
        let sealed = CassiniDocument.read(try CassiniDocument.create(source, transcript: fresh, title: "Newer", processing: JSONObject(),
                                                                     carrying: CassiniDocument.read(source)))
        #expect(sealed.state == .ok)
        #expect(sealed.manifest?.has("x") == false)
        #expect(sealed.variants.map(\.id) == ["words"])
    }

    /** Beside a verified document the manifest is already that document's: carrying another one is a caller's mistake. */
    @Test func aSealBesideADocumentCarriesNothingElse() throws {
        let document = try documentWithPrivateData()
        #expect(throws: CassiniError.self) {
            try CassiniDocument.create(document, transcript: fresh, title: "Both", processing: JSONObject(),
                                       existing: CassiniDocument.read(document), carrying: CassiniDocument.read(try staleTwin(document)))
        }
    }

    /** A verified source keeps `x` through its own manifest, beside every earlier variant. */
    @Test func aSealBesideAVerifiedDocumentKeepsItsPrivateMember() throws {
        let document = try documentWithPrivateData()
        let before = CassiniDocument.read(document)
        let after = CassiniDocument.read(try CassiniDocument.create(document, transcript: fresh, title: "Next", processing: JSONObject(),
                                                                    existing: before))
        #expect(after.state == .ok)
        #expect(after.manifest?["x"]?.serialized() == before.manifest?["x"]?.serialized())
        #expect(after.variants.prefix(2).map(\.id) == before.variants.map(\.id))
        #expect(after.variants.prefix(2).map(\.body) == before.variants.map(\.body))
    }
}
