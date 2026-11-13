@testable import CassiniCore
import Foundation
import Testing

private func disagreements(_ document: CassiniDocument) -> [String] {
    document.warnings.filter { $0.hasPrefix("tag-manifest-disagreement") }
}

/**
 * A verified file may carry copies that disagree with its manifest; the manifest is the record, so it reads as `ok`
 * with a warning. Writing from it must not propagate those copies (SPEC.md "Writing a file": keep summary tags and
 * manifest in agreement).
 */
@Suite(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
struct StaleCopiesInPublishedVectorsTests {
    static let vectors = ["007-chunk-count-too-high", "008-chunk-count-too-low", "017-dangling-transcript-id"]

    /** [name] copied into [dir], read with its audio verified: `ok`, but with stale copies. */
    func source(_ name: String, in dir: URL) throws -> (url: URL, document: CassiniDocument) {
        let url = dir.appendingPathComponent("\(name).opus")
        try Data(try Conformance.vector(name)).write(to: url)
        let document = CassiniDocument.read(url)
        try #require(document.state == .ok)
        try #require(!disagreements(document).isEmpty)
        return (url, document)
    }

    @Test(arguments: vectors)
    func aSealBesideStaleCopiesWritesOnlyAgreeingOnes(_ name: String) throws {
        try withTemporaryDirectory { dir in
            let (url, before) = try source(name, in: dir)
            let transcript = Transcript([Word("spk_new", 0, 20, "Hello")])
            let after = try CassiniDocument.create(url, transcript: transcript, title: "Ignored", processing: JSONObject(), existing: before,
                                                   speakerLabels: [:], target: dir.appendingPathComponent("sealed.opus"))
            #expect(after.state == .ok)
            #expect(disagreements(after).isEmpty, "\(after.warnings)")
            #expect(after.selected()?.transcript == transcript)
            #expect(Array(after.variants.dropLast().map(\.body)) == before.variants.map(\.body))
        }
    }

    @Test(arguments: vectors)
    func aRelabelOfStaleCopiesWritesOnlyAgreeingOnes(_ name: String) throws {
        try withTemporaryDirectory { dir in
            let (url, before) = try source(name, in: dir)
            let speaker = try #require(before.manifest?["speakers"]?.array?.first?.object?["id"]?.string)
            let after = try CassiniDocument.relabel(url, existing: before, labels: [speaker: "Anna"], target: dir.appendingPathComponent("relabelled.opus"))
            #expect(after.state == .ok)
            #expect(disagreements(after).isEmpty, "\(after.warnings)")
            #expect(after.speakerLabel(speaker) == "Anna")
            #expect(after.variants.map(\.body) == before.variants.map(\.body))
        }
    }

    @Test(arguments: vectors)
    func aRetitleOfStaleCopiesWritesOnlyAgreeingOnes(_ name: String) throws {
        try withTemporaryDirectory { dir in
            let (url, before) = try source(name, in: dir)
            let after = try CassiniDocument.retitle(url, existing: before, title: "New", target: dir.appendingPathComponent("retitled.opus"))
            #expect(after.state == .ok)
            #expect(disagreements(after).isEmpty, "\(after.warnings)")
            #expect(after.title == "New")
            #expect(after.variants.map(\.body) == before.variants.map(\.body))
        }
    }
}

@Suite struct DerivedTagsTests {
    let transcript = Transcript([Word("spk_1", 0, 20, "Hello"), Word("spk_2", 20, 40, "Hi")], language: "it")

    func sealed(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("source.opus")
        try Data(try CassiniDocument.create(silence(), transcript: transcript, title: "Meeting", processing: JSONObject())).write(to: url)
        return url
    }

    /** Summary and mirror copies that no reader checks are still rebuilt: repeats collapse, absent members lose their tag. */
    @Test func summaryAndMirrorCopiesFollowTheManifest() throws {
        try withTemporaryDirectory { dir in
            let url = try sealed(in: dir)
            var existing = CassiniDocument.read(url)
            var meeting = try #require(existing.manifest?["meeting"]?.object)
            meeting["jobId"] = .string("job-1")
            meeting["attemptNumber"] = .int(2)
            existing.manifest?["meeting"] = .object(meeting)
            existing.comments += ["CASSINI_ROOM_ID=rm_0000000000000000", "cassini_meeting_id=mtg_other", "CASSINI_SPEAKER_COUNT=9"]
            let after = try CassiniDocument.retitle(url, existing: existing, title: "Altro", target: dir.appendingPathComponent("target.opus"))
            #expect(comments(after) { $0 == "CASSINI_MEETING_ID" } == ["CASSINI_MEETING_ID=\(try meeting.string("id"))"])
            #expect(comments(after) { $0 == "CASSINI_SPEAKER_COUNT" } == ["CASSINI_SPEAKER_COUNT=2"])
            #expect(comments(after) { $0 == "CASSINI_ROOM_ID" }.isEmpty)
            #expect(comments(after) { $0 == "CASSINI_JOB_ID" } == ["CASSINI_JOB_ID=job-1"])
            #expect(comments(after) { $0 == "CASSINI_ATTEMPT_NUMBER" } == ["CASSINI_ATTEMPT_NUMBER=2"])
        }
    }

    /** A rewrite replaces each copy where it stands, so tags it keeps do not move. */
    @Test func copiesAreReplacedWhereTheyStand() throws {
        try withTemporaryDirectory { dir in
            let url = try sealed(in: dir)
            let before = CassiniDocument.read(url)
            let after = try CassiniDocument.relabel(url, existing: before, labels: ["spk_1": "Anna"], target: dir.appendingPathComponent("target.opus"))
            let unchanged: (String) -> Bool = { !$0.hasPrefix("CASSINI_PAYLOAD_") || $0 == "CASSINI_PAYLOAD_SCHEMA" || $0 == "CASSINI_PAYLOAD_MIME" }
            #expect(comments(after, named: unchanged) == comments(before, named: unchanged))
            #expect(after.comments.map(CassiniDocument.tagName) == before.comments.map(CassiniDocument.tagName))
        }
    }

    /** Two speaker ids that differ in their bytes are two speakers, however Unicode would compare them. */
    @Test func canonicallyEquivalentSpeakerIdsStayApart() throws {
        let composed = "Ren\u{E9}", decomposed = "Rene\u{301}"
        let transcript = Transcript([Word(composed, 0, 20, "Hello"), Word(decomposed, 20, 40, "Hi")])
        let document = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: transcript, title: "Two", processing: JSONObject(),
                                                                         speakerLabels: [composed: "One"]))
        #expect(document.state == .ok)
        #expect(document.manifest?["speakers"]?.array?.count == 2)
        #expect(document.speakerLabel(composed) == "One")
        #expect(sameBytes(document.speakerLabel(decomposed), decomposed))
    }

    @Test(arguments: [false, true])
    func optionalSpeakerHintsMatchExactIDBytes(preservingForeignHints: Bool) throws {
        let composed = "voice-\u{E9}", decomposed = "voice-e\u{301}"
        let words = Transcript([Word(composed, 0, 20, "Hello"), Word(decomposed, 20, 40, "Hi")], language: "en")
        let initial = try CassiniDocument.create(silence(), transcript: words, title: "English conversation", processing: JSONObject())
        var source = CassiniDocument.read(initial)
        if preservingForeignHints, let roster = source.manifest?["speakers"]?.array {
            source.manifest?["speakers"] = .array(roster.map { entry in
                guard var value = entry.object, sameBytes(value["id"]?.string, decomposed) else { return entry }
                value["colourIndex"] = .int(8)
                value["provenance"] = .string("source")
                return .object(value)
            })
        }
        let bytes = try CassiniDocument.create(initial, transcript: words, title: "English conversation",
            processing: JSONObject(), existing: source,
            speakerHints: [composed: JSONObject([("colourIndex", .int(2)), ("provenance", .string("user"))])])
        let result = CassiniDocument.read(bytes)
        #expect(result.state == .ok)
        let roster = try #require(result.manifest?["speakers"]?.array)
        let own = try #require(roster.compactMap(\.object).first { sameBytes($0["id"]?.string, composed) })
        let other = try #require(roster.compactMap(\.object).first { sameBytes($0["id"]?.string, decomposed) })
        #expect(try own.number("colourIndex") == 2)
        #expect(own["provenance"]?.string == "user")
        if preservingForeignHints {
            #expect(try other.number("colourIndex") == 8)
            #expect(other["provenance"]?.string == "source")
        } else {
            #expect(other["colourIndex"] == nil)
            #expect(other["provenance"] == nil)
        }
    }

    /** Without CASSINI_FORMAT nothing is Cassini metadata, so an undecodable CASSINI_ comment is only a foreign one. */
    @Test func anUndecodableCassiniCommentInPlainAudioStaysPlainAudio() throws {
        let stray = Array("CASSINI_NOTE=Caf".utf8) + [0xE9]
        let document = CassiniDocument.read(try silence(["X_CUSTOM=keep=me"], opaque: [stray]))
        #expect(document.state == .plainAudio)
        #expect(document.opaqueComments == [stray])
        #expect(document.warnings == ["non-utf8-comment: CASSINI_NOTE"])
    }

    @Test func anUndecodableCassiniCommentBesideTheFormatIsInvalid() throws {
        let stray = Array("CASSINI_NOTE=Caf".utf8) + [0xE9]
        let document = CassiniDocument.read(try silence(["CASSINI_FORMAT=\(CassiniDocument.format)"], opaque: [stray]))
        #expect(document.state == .invalidMetadata)
        #expect(document.warnings.contains("invalid-utf8-tag: CASSINI_NOTE"))
    }
}

/** A write that fails after its target exists must remove it. Each case gets past the source scan and fails later. */
@Suite struct FailedWritesLeaveNoTargetTests {
    let transcript = Transcript([Word("spk_1", 0, 20, "Hello")])

    /** A verified document whose manifest names a different audio digest than the audio beside it. */
    func mismatched(in dir: URL) throws -> (url: URL, existing: CassiniDocument) {
        let url = dir.appendingPathComponent("source.opus")
        try Data(try CassiniDocument.create(silence(), transcript: transcript, title: "Meeting", processing: JSONObject())).write(to: url)
        var existing = CassiniDocument.read(url)
        var integrity = try #require(existing.manifest?["integrity"]?.object)
        integrity["opusAudioSha256"] = .string(String(repeating: "0", count: 64))
        existing.manifest?["integrity"] = .object(integrity)
        try #require(existing.state == .ok)
        return (url, existing)
    }

    @Test func aSealThatDoesNotReadBackRemovesItsTarget() throws {
        try withTemporaryDirectory { dir in
            let (url, existing) = try mismatched(in: dir)
            let target = dir.appendingPathComponent("target.opus")
            #expect(throws: CassiniError.self) {
                try CassiniDocument.create(url, transcript: transcript, title: "Meeting", processing: JSONObject(), existing: existing,
                                           speakerLabels: [:], target: target)
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func aRelabelThatFailsRemovesItsTarget() throws {
        try withTemporaryDirectory { dir in
            let (url, existing) = try mismatched(in: dir)
            let target = dir.appendingPathComponent("target.opus")
            #expect(throws: CassiniError.self) { try CassiniDocument.relabel(url, existing: existing, labels: ["spk_1": "Anna"], target: target) }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func aRetitleThatFailsRemovesItsTarget() throws {
        try withTemporaryDirectory { dir in
            let (url, existing) = try mismatched(in: dir)
            let target = dir.appendingPathComponent("target.opus")
            #expect(throws: CassiniError.self) { try CassiniDocument.retitle(url, existing: existing, title: "Altro", target: target) }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }
}

/** A writer recognises derived tags by the bytes of their names, as the reader does. */
@Suite struct DerivedTagNamesTests {
    // "CASSINI_PAYLOAD_CHUNK_COUNT" with KELVIN SIGN, which Swift's `==` equates with "K": a foreign tag to a reader.
    let lookalike = "CASSINI_PAYLOAD_CHUN\u{212A}_COUNT=9"

    @Test func aForeignTagThatLooksLikeADerivedOneSurvivesARelabel() throws {
        let sealed = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: Transcript([Word("spk_1", 0, 20, "Hello")]),
                                                                     title: "Meeting", processing: JSONObject()))
        let out = ArraySink()
        try OggOpus.rewrite(ArraySource(silence()), tags: CassiniDocument.tagsPacket([lookalike] + sealed.comments), to: out)
        try withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("a.opus")
            try Data(out.bytes).write(to: source)
            let before = CassiniDocument.read(source)
            try #require(before.state == .ok)
            let after = try CassiniDocument.relabel(source, existing: before, labels: ["spk_1": "Anna"], target: dir.appendingPathComponent("b.opus"))
            #expect(after.state == .ok)
            #expect(after.comments.filter { $0.utf8.elementsEqual(lookalike.utf8) }.count == 1)
            #expect(after.comments.filter { $0.utf8.starts(with: "CASSINI_PAYLOAD_CHUNK_COUNT=".utf8) }.count == 1)
        }
    }
}
