import XCTest
import CassiniEngine
import CassiniSherpa
@testable import Cassini

/// `AppEnvironment.speechTranscriber`: Parakeet Ultra when the runtime is linked, its model installed and the device
/// capable, else Apple Speech (decision D2).
@MainActor final class SpeechCompositionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// Ultra's files as sparse files of their pinned sizes, with the marker.
    private func installUltra() throws {
        let directory = ModelCatalog.parakeet.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in ModelCatalog.parakeet.artifacts {
            let url = directory.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.size))
            try handle.close()
        }
        try Data(ModelCatalog.parakeet.markerValue.utf8)
            .write(to: directory.appendingPathComponent(ModelCatalog.parakeet.markerFile))
    }

    func testWithoutTheModelTheAppTranscribesWithAppleSpeech() {
        XCTAssertEqual(AppEnvironment.speechTranscriber(models: root, physicalMemory: 8 << 30).recognizer, .appleSpeech)
    }

    func testAnInstalledUltraIsUsedOnlyWithTheRuntimeAndTheMemory() throws {
        try installUltra()
        XCTAssertEqual(AppEnvironment.speechTranscriber(models: root, physicalMemory: 4 << 30).recognizer, .appleSpeech,
                       "a 4 GB device stays on Apple Speech until the device gate says otherwise")
        XCTAssertEqual(AppEnvironment.speechTranscriber(models: root, physicalMemory: 8 << 30).recognizer,
                       SherpaRuntime.isLinked ? .parakeet : .appleSpeech)
    }
}
