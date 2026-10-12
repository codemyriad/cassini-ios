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
            let transcript = Transcript([Word("spk_new", 0, 20, "Ciao")])
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
            let after = try CassiniDocument.retitle(url, existing: before, title: "Nuovo", target: dir.appendingPathComponent("retitled.opus"))
            #expect(after.state == .ok)
            #expect(disagreements(after).isEmpty, "\(after.warnings)")
            #expect(after.title == "Nuovo")
            #expect(after.variants.map(\.body) == before.variants.map(\.body))
        }
    }
}

@Suite struct DerivedTagsTests {
    let transcript = Transcript([Word("spk_1", 0, 20, "Ciao"), Word("spk_2", 20, 40, "Salve")], language: "it")

    func sealed(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("source.opus")
        try Data(try CassiniDocument.create(silence(), transcript: transcript, title: "Riunione", processing: JSONObject())).write(to: url)
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
        let transcript = Transcript([Word(composed, 0, 20, "Ciao"), Word(decomposed, 20, 40, "Salve")])
        let document = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: transcript, title: "Due", processing: JSONObject(),
                                                                         speakerLabels: [composed: "One"]))
        #expect(document.state == .ok)
        #expect(document.manifest?["speakers"]?.array?.count == 2)
        #expect(document.speakerLabel(composed) == "One")
        #expect(sameBytes(document.speakerLabel(decomposed), decomposed))
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
    let transcript = Transcript([Word("spk_1", 0, 20, "Ciao")])

    /** A verified document whose manifest names a different audio digest than the audio beside it. */
    func mismatched(in dir: URL) throws -> (url: URL, existing: CassiniDocument) {
        let url = dir.appendingPathComponent("source.opus")
        try Data(try CassiniDocument.create(silence(), transcript: transcript, title: "Riunione", processing: JSONObject())).write(to: url)
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
                try CassiniDocument.create(url, transcript: transcript, title: "Riunione", processing: JSONObject(), existing: existing,
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
