import Foundation
import CassiniCore

/// Ogg Opus files and Cassini documents for the import and export tests.
enum PortableFixtures {
    static let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]

    /// `packets` 20 ms packets of Opus silence behind `comments`.
    static func silence(packets: Int = 50, comments: [String] = ["X_CUSTOM=keep=me"]) throws -> [UInt8] {
        let tags = CassiniDocument.tagsPacket(comments)
        let stream = OggOpus.Stream(head: head, tags: tags, audio: Array(repeating: [0xF8, 0xFF, 0xFE], count: packets),
                                    finalGranule: Int64(packets * 960), validFraming: true)
        return try OggOpus.mux(stream, tags: tags)
    }

    static func document(_ words: [Word], title: String, labels: [String: String] = [:], language: String = "it") throws -> [UInt8] {
        try CassiniDocument.create(silence(), transcript: Transcript(words, language: language), title: title,
                                   processing: JSONObject(), speakerLabels: labels)
    }

    /// `bytes` with the comments `keep` lets through.
    static func rewritingComments(_ bytes: [UInt8], _ keep: (String) -> String?) throws -> [UInt8] {
        let document = CassiniDocument.read(bytes)
        return try OggOpus.mux(OggOpus.read(bytes), tags: CassiniDocument.tagsPacket(document.comments.compactMap(keep)))
    }

    /// Private data as a desktop app writes it: notes under `x["gocassini.com"]`, a foreign domain, an integer above 2^53.
    static let privateText = #"{"gocassini.com":{"notes":[{"atMs":1200,"text":"Budget next week"}]},"#
        + #""example.com":{"ticket":"OPS-14","count":9007199254740993}}"#

    /// A verified document of `words` whose manifest carries `privateText` as `x`.
    static func documentWithPrivateData(_ words: [Word], title: String) throws -> [UInt8] {
        let first = try document(words, title: title)
        var base = CassiniDocument.read(first)
        base.manifest?["x"] = .object(try JSON.parseObject(privateText))
        return try CassiniDocument.create(first, transcript: Transcript(words, language: "it"), title: title,
                                          processing: JSONObject(), existing: base)
    }

    /// `document`'s tags over other audio: its stale twin.
    static func staleTwin(_ document: [UInt8]) throws -> [UInt8] {
        try OggOpus.mux(OggOpus.read(silence(packets: 20)), tags: OggOpus.read(document).tags)
    }

    /// `document` with its audio digest copy contradicting the manifest, so its audio cannot be verified.
    static func unverifiedTwin(_ document: [UInt8]) throws -> [UInt8] {
        try rewritingComments(document) { comment in
            comment.hasPrefix("CASSINI_AUDIO_OPUS_SHA256=") ? "CASSINI_AUDIO_OPUS_SHA256=" + String(repeating: "0", count: 64) : comment
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-notebook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The published conformance suite beside this repository (see CassiniCoreTests `Conformance`).
enum Conformance {
    static let directory = ProcessInfo.processInfo.environment["CASSINI_CONFORMANCE"].map { URL(fileURLWithPath: $0) } ??
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../cassini-format/spec/conformance").standardized
    static let available = FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path)
    static let missing = "Check out cassini-format beside this repository for the published conformance suite"

    static func vector(_ name: String) -> URL { directory.appendingPathComponent("opus/\(name).opus") }
}
