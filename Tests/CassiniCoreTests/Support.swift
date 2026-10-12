@testable import CassiniCore
import Foundation
import Testing

/**
 * The published suite lives in ../cassini-format; CASSINI_CONFORMANCE overrides the location, and
 * CASSINI_CONFORMANCE_REQUIRED=1 turns a missing suite into a failure instead of skipped tests.
 */
enum Conformance {
    static let environment = ProcessInfo.processInfo.environment
    static let required = environment["CASSINI_CONFORMANCE_REQUIRED"] == "1"
    static let directory = environment["CASSINI_CONFORMANCE"].map { URL(fileURLWithPath: $0) } ??
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../cassini-format/spec/conformance").standardized
    static let available: Bool = {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }()
    static let missing = "Check out cassini-format beside this repository for the published conformance suite"

    static func vector(_ name: String) throws -> [UInt8] { try bytes(directory.appendingPathComponent("opus/\(name).opus")) }
}

@Test func theConformanceSuiteIsPresentWhenRequired() {
    if Conformance.required { #expect(Conformance.available, "Required Cassini conformance directory is missing: \(Conformance.directory.path)") }
}

func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

let opusHead = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]

/** One packet of Opus silence behind a tags packet of [comments] and [opaque] entries. */
func silence(_ comments: [String] = ["X_CUSTOM=keep=me"], opaque: [[UInt8]] = []) throws -> [UInt8] {
    let tags = CassiniDocument.tagsPacket(comments, opaque: opaque)
    return try OggOpus.mux(OggOpus.Stream(head: opusHead, tags: tags, audio: [[0xF8, 0xFF, 0xFE]], finalGranule: 960, validFraming: true), tags: tags)
}

/** Runs [body] with a fresh directory that is removed afterwards. */
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/** The comments whose names (ASCII case folded) satisfy [filter]. */
func comments(_ document: CassiniDocument, named filter: (String) -> Bool) -> [String] {
    document.comments.filter { filter(CassiniDocument.tagName($0)) }
}
