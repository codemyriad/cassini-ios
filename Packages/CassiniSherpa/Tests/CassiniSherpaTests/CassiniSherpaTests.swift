import Foundation
import Testing
import CassiniEngine
import CassiniSherpa

/// The host side of CassiniSherpa: `swift test` on macOS links no native runtime, so neither native object can be made.
/// The configurations they copy are tested in CassiniEngine (`ParakeetDecoderConfigTests`, `SileroDetectorConfigTests`).
@Test func theMacBuildLinksNoNativeRuntime() {
    #if os(macOS)
    #expect(!SherpaRuntime.isLinked)
    #expect(throws: SherpaError.notLinked) { try ParakeetDecoder(files: ParakeetFiles(directory: URL(fileURLWithPath: "/nonexistent"))) }
    #expect(throws: SherpaError.notLinked) { try SileroDetector(config: SileroConfig(model: URL(fileURLWithPath: "/nonexistent"))) }
    #expect(throws: SherpaError.notLinked) { try SherpaRuntime.speech.makeDecoder(ParakeetConfig(ParakeetFiles(directory: URL(fileURLWithPath: "/m")))) }
    #endif
}
