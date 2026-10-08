@testable import CassiniCore
import Foundation
import XCTest

/** The published suite lives in ../cassini-format; CASSINI_CONFORMANCE overrides, CASSINI_CONFORMANCE_REQUIRED=1 forbids skipping. */
func conformanceDirectory() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    let directory = env["CASSINI_CONFORMANCE"].map { URL(fileURLWithPath: $0) } ??
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../cassini-format/spec/conformance").standardized
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    if env["CASSINI_CONFORMANCE_REQUIRED"] == "1" { XCTAssertTrue(exists, "Required Cassini conformance directory is missing: \(directory.path)") }
    try XCTSkipUnless(exists, "Checkout cassini-format beside this repository for the published conformance suite")
    return directory
}

func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

func silence() throws -> [UInt8] {
    let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
    let tags = CassiniDocument.tagsPacket(["X_CUSTOM=keep=me"])
    return try OggOpus.mux(OggOpus.Stream(head: head, tags: tags, audio: [[0xF8, 0xFF, 0xFE]], finalGranule: 960, validFraming: true), tags: tags)
}

final class CassiniDocumentTests: XCTestCase {
    func testPublishedConformanceVectors() throws {
        let directory = try conformanceDirectory()
        let index = try JSON.parseObject(String(decoding: try bytes(directory.appendingPathComponent("index.json")), as: UTF8.self))
        var failures: [String] = []
        for vector in try index.array("vectors").compactMap({ $0.object }) {
            let expected = try vector.object("expect")
            let id = try vector.string("id")
            let doc = CassiniDocument.read(try bytes(directory.appendingPathComponent(try vector.string("file"))))
            let state = try expected.string("state")
            if state != doc.state && !(state == "unverified" && doc.state == "ok") { failures.append("\(id): expected \(state), got \(doc.state) \(doc.warnings)") }
            if let ids = expected["transcriptIds"]?.array { XCTAssertEqual(ids.compactMap { $0.string }, doc.variants.map { $0.id }, id) }
            if let wanted = expected["defaultTranscriptId"]?.string, !wanted.isEmpty { XCTAssertEqual(wanted, doc.defaultId, id) }
            if let counts = expected["wordCounts"]?.object {
                var expectedCounts: [String: Int64] = [:]
                for key in counts.keys { expectedCounts[key] = try counts.number(key) }
                var actual: [String: Int64] = [:]
                for v in doc.variants { if let t = v.transcript { actual[v.id] = Int64(t.words.count) } }
                XCTAssertEqual(expectedCounts, actual, id)
            }
            if doc.manifest == nil { XCTAssertTrue(doc.variants.isEmpty, id) }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testRetiredAsrProvenanceSurvivesAnInt8Retranscription() throws {
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
        XCTAssertEqual("ok", next.state)
        XCTAssertEqual(2, next.variants.count)
        XCTAssertEqual(original.variants[0].body, next.variants[0].body)
        let path: (CassiniDocument) -> JSON? = { $0.manifest?["provenance"]?.object?["speechToText"]?.object?[original.variants[0].id] }
        XCTAssertEqual(path(original)?.serialized(), path(next)?.serialized())
        XCTAssertEqual(try OggOpus.read(first).digest(), try OggOpus.read(nextBytes).digest())
    }

    func testNewDocumentSealsAudioAndAppendedVariantPreservesExtensions() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Ciao")], language: "it")
        let first = try CassiniDocument.create(silence(), transcript: transcript, title: "Italian sample", processing: JSONObject([("engine", .string("sherpa-onnx"))]))
        let original = CassiniDocument.read(first)
        XCTAssertEqual("ok", original.state); XCTAssertEqual(transcript, original.selected()?.transcript)
        XCTAssertTrue(original.comments.contains("X_CUSTOM=keep=me"))
        var withPrivate = original
        withPrivate.comments += ["CASSINI_AUDIO_FUTURE=keep", "CASSINI_PAYLOAD_FUTURE=keep"]
        withPrivate.manifest!["extension"] = .object(JSONObject([("keep", .bool(true))]))
        var speakers = withPrivate.manifest!["speakers"]!.array!
        var speaker = speakers[0].object!; speaker["pronouns"] = .string("they"); speakers[0] = .object(speaker)
        withPrivate.manifest!["speakers"] = .array(speakers)
        var english = transcript; english.language = "en"
        let next = CassiniDocument.read(try CassiniDocument.create(first, transcript: english, title: "Ignored", processing: JSONObject(), existing: withPrivate))
        XCTAssertEqual("ok", next.state); XCTAssertEqual(2, next.variants.count)
        XCTAssertTrue(next.comments.contains("CASSINI_AUDIO_FUTURE=keep")); XCTAssertTrue(next.comments.contains("CASSINI_PAYLOAD_FUTURE=keep"))
        XCTAssertEqual(next.manifest?["extension"]?.object?["keep"], .bool(true))
        XCTAssertEqual(next.manifest?["speakers"]?.array?[0].object?["pronouns"], .string("they"))
        XCTAssertEqual(original.variants[0].body, next.variants[0].body)
        XCTAssertEqual(try OggOpus.read(first).digest(),
                       try OggOpus.read(try CassiniDocument.create(first, transcript: transcript, title: "Again", processing: JSONObject(), existing: original)).digest())
    }

    private func relabelled(_ data: [UInt8], _ labels: [String: String]) throws -> (CassiniDocument, CassiniDocument) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.opus")
        try Data(data).write(to: source)
        let before = CassiniDocument.read(source)
        return (before, try CassiniDocument.relabel(source, existing: before, labels: labels, target: dir.appendingPathComponent("b.opus")))
    }

    private func tags(_ doc: CassiniDocument, _ filter: (String) -> Bool) -> [String] {
        doc.comments.filter { filter(String($0[..<($0.firstIndex(of: "=") ?? $0.endIndex)])) }
    }

    func testRelabelChangesOnlyTheLabels() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Ciao"), Word("spk_2", 20, 40, "Salve")], language: "it")
        let first = try CassiniDocument.create(silence(), transcript: transcript, title: "Two", processing: JSONObject([("engine", .string("sherpa-onnx"))]))
        var base = CassiniDocument.read(first)
        base.manifest!["x"] = .object(JSONObject([("keep", .bool(true))]))
        var speakers = base.manifest!["speakers"]!.array!
        var speaker = speakers[0].object!; speaker["pronouns"] = .string("she"); speakers[0] = .object(speaker)
        base.manifest!["speakers"] = .array(speakers)
        let (before, after) = try relabelled(try CassiniDocument.create(first, transcript: transcript, title: "Ignored", processing: JSONObject(), existing: base),
                                             ["spk_1": "  Anna "])
        XCTAssertEqual("ok", after.state); XCTAssertTrue(after.warnings.isEmpty)
        XCTAssertEqual("Anna", after.speakerLabel("spk_1")); XCTAssertEqual("spk_2", after.speakerLabel("spk_2"))
        XCTAssertEqual(after.manifest?["speakers"]?.array?[0].object?["pronouns"], .string("she"))
        XCTAssertEqual(after.manifest?["x"]?.object?["keep"], .bool(true))
        XCTAssertEqual(before.manifest?["meeting"]?.serialized(), after.manifest?["meeting"]?.serialized())
        XCTAssertEqual(before.manifest?["integrity"]?.serialized(), after.manifest?["integrity"]?.serialized())
        XCTAssertEqual(before.variants.map { $0.id }, after.variants.map { $0.id })
        XCTAssertEqual(before.variants.map { $0.body }, after.variants.map { $0.body })
        XCTAssertEqual(tags(before) { !$0.hasPrefix("CASSINI_PAYLOAD_") }, tags(after) { !$0.hasPrefix("CASSINI_PAYLOAD_") })
        let fixed: (String) -> Bool = { $0 == "CASSINI_PAYLOAD_SCHEMA" || $0 == "CASSINI_PAYLOAD_MIME" }
        XCTAssertEqual(tags(before, fixed), tags(after, fixed))
        XCTAssertNotEqual(tags(before) { $0 == "CASSINI_PAYLOAD_SHA256" }, tags(after) { $0 == "CASSINI_PAYLOAD_SHA256" })
        XCTAssertNotEqual(tags(before) { $0 == "CASSINI_PAYLOAD_RAW_BYTES" }, tags(after) { $0 == "CASSINI_PAYLOAD_RAW_BYTES" })
        var expected = before.manifest!
        var renamed = expected["speakers"]!.array!
        var first0 = renamed[0].object!; first0["label"] = .string("Anna"); renamed[0] = .object(first0)
        expected["speakers"] = .array(renamed)
        XCTAssertEqual(expected.serialized(), after.manifest?.serialized())
    }

    func testRelabelRejectsUnknownSpeakersAndBlankLabels() throws {
        let data = try CassiniDocument.create(silence(), transcript: Transcript([Word("spk_1", 0, 20, "Ciao")], language: "it"), title: "One", processing: JSONObject())
        for labels in [["spk_9": "Anna"], ["spk_1": "  "]] {
            XCTAssertThrowsError(try relabelled(data, labels), "\(labels)")
        }
    }

    func testRelabelConformanceVectorWithUnknownMembers() throws {
        let file = try conformanceDirectory().appendingPathComponent("opus/014-unknown-manifest-member.opus")
        let (before, after) = try relabelled(try bytes(file), ["spk_a": "Anna"])
        XCTAssertEqual("ok", after.state); XCTAssertEqual("Anna", after.speakerLabel("spk_a"))
        XCTAssertEqual(before.speakerLabel("spk_b"), after.speakerLabel("spk_b"))
        XCTAssertTrue(after.manifest!.has("cassiniFutureField"))
        XCTAssertEqual(before.manifest?["speakers"]?.array?[0].object?["pronouns"], after.manifest?["speakers"]?.array?[0].object?["pronouns"])
        XCTAssertEqual(before.variants.map { $0.body }, after.variants.map { $0.body })
        XCTAssertEqual(before.manifest?["integrity"]?.object?["opusAudioSha256"], after.manifest?["integrity"]?.object?["opusAudioSha256"])
    }

    func testStrictPayloadRejectsDuplicatesTrailingGzipAndBadLengths() throws {
        for text in ["{\"x\":1,\"x\":2}", "{\"a\":{\"x\":1,\"x\":2}}", "{\"x\":NaN}", "{\"x\":01}", "{'x':1}"] {
            XCTAssertThrowsError(try JSON.parseObject(text), text)
        }
        let (ref, tags) = try CassiniPayload.encode(prefix: "TEST_", mime: CassiniPayload.mime, text: "{\"ok\":true}")
        let chunk = String(tags.last!.split(separator: "=", maxSplits: 1)[1])
        XCTAssertEqual("{\"ok\":true}", try CassiniPayload.decode([chunk], rawBytes: ref.number("rawBytes"), gzipBytes: ref.number("gzipBytes"), sha256: ref.string("sha256")))
        let compressed = try ref.number("gzipBytes")
        var standard = chunk.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        let raw = [UInt8](Data(base64Encoded: standard)!)
        let doubled = CassiniPayload.base64url(raw + raw)
        XCTAssertThrowsError(try CassiniPayload.decode([doubled], rawBytes: ref.number("rawBytes"), gzipBytes: compressed * 2, sha256: ref.string("sha256")))
    }

    func testTruncatedAudioKeepsReadableMetadata() throws {
        let data = try CassiniDocument.create(silence(), transcript: Transcript([]), title: "Truncated", processing: JSONObject())
        let doc = CassiniDocument.read(Array(data.dropLast()))
        XCTAssertEqual("unverified", doc.state)
        XCTAssertNotNil(doc.selected()?.transcript)
    }

    func testCrcFailureKeepsTranscriptButDoesNotVerifyAudio() throws {
        var data = try CassiniDocument.create(silence(), transcript: Transcript([]), title: "CRC", processing: JSONObject())
        data[22] ^= 1
        let doc = CassiniDocument.read(data)
        XCTAssertEqual("unverified", doc.state); XCTAssertNotNil(doc.selected()?.transcript)
    }

    func testTokensBecomeWordsWithoutStretchingOverPunctuation() throws {
        let words = try Transcript.timedWordsFromTokens(["▁Ciao", ",", "▁come", "▁va", "?"],
                                                        timestamps: [0.0, 0.9, 1.0, 1.4, 2.0], durations: [0.4, 0.0, 0.3, 0.2, 0.08])
        XCTAssertEqual(words.map { $0.word }, [Word("spk_1", 0, 400, "Ciao,"), Word("spk_1", 1000, 1300, "come"), Word("spk_1", 1400, 1600, "va?")])
        XCTAssertEqual(words.map { $0.capMs }, [900, 1300, 2080])
    }
}
