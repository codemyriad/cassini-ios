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
        let file = try bytes(Conformance.directory.appendingPathComponent(vector.file))
        let document = CassiniDocument.read(file)
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
        if let wanted = expect["speakerIds"]?.array {
            #expect(wanted.compactMap { $0.string } == document.manifest?["speakers"]?.array?.compactMap { $0.object?["id"]?.string })
        }
        if let wanted = expect["audioOpusSha256"]?.string {
            let claimed = try document.manifest.map { try $0.object("integrity").string("opusAudioSha256") }
            #expect(try claimed ?? OggOpus.read(file).digest() == wanted)
        }
        if let wanted = expect["manifestKind"]?.string { #expect(document.manifest?["kind"]?.string == wanted) }
        if let wanted = expect["manifestVersion"] { #expect(document.manifest?["version"] == wanted) }
        if let wanted = expect["formatId"]?.string {
            #expect(comments(document) { $0 == "CASSINI_FORMAT" } == ["CASSINI_FORMAT=\(wanted)"])
        }
        let reported = document.warnings + document.variants.compactMap { $0.error }
        let observed = Observation(document, reported: reported)
        if let wanted = expect["classification"]?.string { #expect(observed.classification == wanted) }
        if let wanted = expect["payloadTrust"]?.string { #expect(observed.payloadTrust == wanted) }
        if let wanted = expect["audioTrust"]?.string { #expect(observed.audioTrust == wanted) }
        if let reference = expect["sameContentAs"]?.string {
            let same = try #require(ConformanceVector.all.first { $0.id == reference })
            let other = CassiniDocument.read(try bytes(Conformance.directory.appendingPathComponent(same.file)))
            // As the runner reads it: the same speech and speakers, though the manifest may carry more (021 pads it).
            #expect(document.manifest?["version"] == other.manifest?["version"])
            #expect(document.manifest?["speakers"] == other.manifest?["speakers"], "speakers differ from \(reference)")
            #expect(document.variants.map { $0.id } == other.variants.map { $0.id })
            #expect(document.variants.map { $0.body } == other.variants.map { $0.body }, "transcript bodies differ from \(reference)")
        }
        // A vector without `warnings` expects none; a warning may only repeat a code the vector names as an error.
        let warnings = try (expect["warnings"]?.array ?? []).compactMap { $0.object }.map { warning in
            let code = try warning.string("code")
            return warning["tag"]?.string.map { "\(code): \($0)" } ?? code
        }
        for warning in warnings { #expect(document.warnings.contains(warning), "missing warning \(warning) in \(document.warnings)") }
        let errorCodes = try (expect["errors"]?.array ?? []).compactMap { $0.object }.map { try $0.string("code") }
        let allowed = Set(warnings.map(code) + errorCodes)
        #expect(document.warnings.allSatisfy { allowed.contains(code($0)) }, "unexpected warnings in \(document.warnings)")
        for error in (expect["errors"]?.array ?? []).compactMap({ $0.object }) {
            let code = try error.string("code")
            if let tag = error["tag"]?.string {
                #expect(reported.contains("\(code): \(tag)"), "missing error \(code): \(tag) in \(reported)")
            } else {
                #expect(reported.contains { self.code($0) == code }, "missing error \(code) in \(reported)")
            }
        }
        let transcripts = document.variants.compactMap { $0.transcript }
        if mustNot.contains("emit-transcript") { #expect(transcripts.isEmpty) }
        if mustNot.contains("discard-transcript") { #expect(!transcripts.isEmpty) }
        if mustNot.contains("report-audio-verified") { #expect(document.state != .ok) }
        if mustNot.contains("fail") { #expect(document.state != .invalidMetadata) }
        if mustNot.contains("present-as-current") { #expect(document.manifest == nil && transcripts.isEmpty) }
        if document.manifest == nil { #expect(document.variants.isEmpty) }
    }

    /**
     * What the suite's runner observes of a full reader, in the index's vocabulary: the classification and trust
     * triple that adapters/adapter-go.py derives from the state.
     */
    struct Observation {
        let classification: String, payloadTrust: String, audioTrust: String

        init(_ document: CassiniDocument, reported: [String]) {
            switch document.state {
            case .plainAudio: (classification, payloadTrust, audioTrust) = ("plain-audio", "not-applicable", "not-applicable")
            case .unknownFormat: (classification, payloadTrust, audioTrust) = ("unsupported-version", "unverified", "unverified")
            case .invalidMetadata:
                let mismatched = reported.contains { $0.hasPrefix("payload-sha256-mismatch") }
                (classification, payloadTrust, audioTrust) = ("damaged-metadata", mismatched ? "mismatched" : "unverified", "unverified")
            case .unreadable: (classification, payloadTrust, audioTrust) = ("crash", "unverified", "unverified")
            case .unverified: (classification, payloadTrust, audioTrust) = ("cassini", "verified", "unverified")
            case .staleAudio: (classification, payloadTrust, audioTrust) = ("cassini", "verified", "mismatched")
            case .ok: (classification, payloadTrust, audioTrust) = ("cassini", "verified", "verified")
            }
        }
    }

    /** The code of a reported warning or error: the text before `: TAG`, if any. */
    func code(_ reported: String) -> String {
        reported.range(of: ": ").map { String(reported[..<$0.lowerBound]) } ?? reported
    }
}
