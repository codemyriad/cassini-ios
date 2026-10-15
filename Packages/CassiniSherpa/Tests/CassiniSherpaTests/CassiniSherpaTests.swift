import Foundation
import Testing
import CassiniSherpa

/// The host side of CassiniSherpa: `swift test` on macOS links no native runtime, and nothing reaches the native
/// loader without every model file.
@Test func theMacBuildLinksNoNativeRuntime() {
    #if os(macOS)
    #expect(!SherpaRuntime.isLinked)
    #expect(throws: SherpaError.notLinked) { try ParakeetDecoder(files: ParakeetFiles(directory: URL(fileURLWithPath: "/nonexistent"))) }
    #endif
}

@Test func presentNeedsEveryFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = ParakeetFiles(directory: directory)
    #expect([files.encoder, files.decoder, files.joiner, files.tokens].map(\.lastPathComponent)
        == ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"])
    for url in [files.encoder, files.decoder, files.joiner] {
        #expect(!files.present())
        try Data().write(to: url)
    }
    #expect(!files.present())
    try FileManager.default.createDirectory(at: files.tokens, withIntermediateDirectories: false)
    #expect(!files.present(), "a directory is not a file")
    try FileManager.default.removeItem(at: files.tokens)
    try Data().write(to: files.tokens)
    #expect(files.present())
}
