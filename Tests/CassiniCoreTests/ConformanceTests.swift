@testable import CassiniCore
import Foundation
import Testing

/** One entry of the published index.json. */
struct ConformanceVector: Sendable, CustomTestStringConvertible {
    let id: String
    let file: String
    let expect: JSONObject
    let alsoAcceptable: [JSONObject]

    var testDescription: String { id }

    static let all: [ConformanceVector] = {
        guard Conformance.available,
              let data = try? bytes(Conformance.directory.appendingPathComponent("index.json")),
              let index = try? JSON.parseObject(String(decoding: data, as: UTF8.self)),
              let vectors = try? index.array("vectors") else { return [] }
        return vectors.compactMap { $0.object }.compactMap { vector in
            guard let id = vector["id"]?.string, let file = vector["file"]?.string, let expect = vector["expect"]?.object else { return nil }
            return ConformanceVector(id: id, file: file, expect: expect, alsoAcceptable: (vector["alsoAcceptable"]?.array ?? []).compactMap { $0.object })
        }
    }()
}

@Suite(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
struct ConformanceTests {
    @Test func theIndexListsVectors() {
        #expect(!ConformanceVector.all.isEmpty)
    }

    // ports: CassiniDocumentTest#publishedConformanceVectors
    @Test(arguments: ConformanceVector.all)
    func publishedConformanceVector(_ vector: ConformanceVector) throws {
        let document = CassiniDocument.read(try bytes(Conformance.directory.appendingPathComponent(vector.file)))
        let expect = vector.expect
        let mustNot = Set((expect["mustNot"]?.array ?? []).compactMap { $0.string })
        let states = try ([expect] + vector.alsoAcceptable).map { try #require(DocumentState(rawValue: $0.string("state"))) }
        // The vectors state what a metadata-only reader concludes. A full reader also verifies the audio, which may
        // turn unverified into ok, unless the vector forbids reporting the audio as verified.
        let forbidsVerifiedAudio = mustNot.contains("report-audio-verified") || expect["audioTrust"] == .string("unverified")
        let upgraded = states[0] == .unverified && document.state == .ok && !forbidsVerifiedAudio
        #expect(states.contains(document.state) || upgraded, "expected \(states), got \(document.state) \(document.warnings)")
        guard document.state == states[0] || upgraded else { return } // An alternative outcome carries its own expectations.

        if let ids = expect["transcriptIds"]?.array { #expect(ids.compactMap { $0.string } == document.variants.map { $0.id }) }
        if let wanted = expect["defaultTranscriptId"]?.string, !wanted.isEmpty { #expect(document.defaultId == wanted) }
        if let counts = expect["wordCounts"]?.object {
            var expected: [String: Int64] = [:]
            for key in counts.keys { expected[key] = try counts.number(key) }
            var actual: [String: Int64] = [:]
            for variant in document.variants { if let transcript = variant.transcript { actual[variant.id] = Int64(transcript.words.count) } }
            #expect(expected == actual)
        }
        for warning in (expect["warnings"]?.array ?? []).compactMap({ $0.object }) {
            let code = try warning.string("code")
            let wanted = warning["tag"]?.string.map { "\(code): \($0)" } ?? code
            #expect(document.warnings.contains(wanted), "missing warning \(wanted) in \(document.warnings)")
        }
        let reported = document.warnings + document.variants.compactMap { $0.error }
        for error in (expect["errors"]?.array ?? []).compactMap({ $0.object }) {
            let code = try error.string("code")
            #expect(reported.contains { $0.hasPrefix(code) }, "missing error \(code) in \(reported)")
        }
        let transcripts = document.variants.compactMap { $0.transcript }
        if mustNot.contains("emit-transcript") { #expect(transcripts.isEmpty) }
        if mustNot.contains("discard-transcript") { #expect(!transcripts.isEmpty) }
        if mustNot.contains("report-audio-verified") { #expect(document.state != .ok) }
        if mustNot.contains("fail") { #expect(document.state != .invalidMetadata) }
        if mustNot.contains("present-as-current") { #expect(document.manifest == nil && transcripts.isEmpty) }
        if document.manifest == nil { #expect(document.variants.isEmpty) }
    }
}
