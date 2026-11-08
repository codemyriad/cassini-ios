import XCTest
import Synchronization
import CassiniEngine
import CassiniInference
import CassiniNotebook
import CassiniWhistle

final class WhistleRecordingAdapterTests: XCTestCase {
    private func transcriber() -> WhistleTranscriber {
        WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                            pipelineAccepted: false, deviceAccepted: false, internalExperiment: true),
                           availableMemory: { Int64.max }) // Simulator laboratory admission only.
    }
    func testBundledEnglishRecordingRunsThroughFIRVADAndNeedle() async throws {
        let url = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let languages = Mutex<[String]>([])
        let result = try await transcriber().transcribe(.init(url: url, language: "it-IT", allowDownload: false)) {
            if case .detectedLanguage(let language) = $0 { languages.withLock { $0.append(language) } }
        }
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertTrue(result.segments.flatMap(\.words).contains { $0.text.lowercased().contains("country") })
        XCTAssertEqual(Set(languages.withLock { $0 }), ["en"], "detected English, never the Italian UI preference")
        XCTAssertFalse(WhistleCapability.pending(bundleVerified: true).available)
    }
    func testSharedDCRecordingsKeepTheExactDesktopSixBoundaries() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CASSINI_WHISTLE_DC"] else {
            throw XCTSkip("separate mandatory Whistle DC gate supplies the shared vector folder")
        }
        let expected = [[105984,189440], [347648,367616], [371200,413184], [416256,458240], [504320,544256], [547328,589312]]
        for name in ["dc-quiet-jfk-v1.wav", "dc-quiet-jfk-v1-control.wav"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let result = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false)) { _ in }
            let actual = result.segments.map { [Int(($0.start * 16000).rounded()), Int(($0.end * 16000).rounded())] }
            XCTAssertEqual(actual, expected, name)
            XCTAssertFalse(result.segments.flatMap(\.words).isEmpty)
            print("WHISTLE_DC \(name) \(actual) \(result.segments.map(\.text))")
        }
    }
}
