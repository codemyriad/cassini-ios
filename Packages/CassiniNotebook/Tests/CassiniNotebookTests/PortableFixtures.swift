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
