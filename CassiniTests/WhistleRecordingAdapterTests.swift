import XCTest
import Synchronization
import CassiniEngine
import CassiniInference
import CassiniNotebook
import CassiniWhistle

final class WhistleRecordingAdapterTests: XCTestCase {
    func testAdmissionHeadroomCanRecoverWithoutRelaunchAndLoadChecksItAgain() async throws {
        let free = Mutex<Int64>(1)
        let transcriber = WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true,
            bundleVerified: true, pipelineAccepted: true, deviceAccepted: true), availableMemory: { free.withLock { $0 } })
        let first = await transcriber.unavailability(locale: .current)
        XCTAssertEqual(first, .memory)
        free.withLock { $0 = Int64(WhistleCapability.loadHeadroom) }
        let recovered = await transcriber.unavailability(locale: .current)
        XCTAssertNil(recovered)
        free.withLock { $0 = 1 }
        do {
            _ = try await transcriber.transcribe(.init(url: URL(fileURLWithPath: "/must-not-open.wav"), language: "", allowDownload: false)) { _ in }
            XCTFail("Low live headroom must refuse before opening the audio or loading a model")
        } catch { XCTAssertEqual(error as? TranscriptionError, .failed(.memory)) }
    }

    private func transcriber() -> WhistleTranscriber {
        WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                            pipelineAccepted: false, deviceAccepted: false, internalExperiment: true),
                           availableMemory: { Int64.max }) // Simulator laboratory admission only.
    }
    func testBundledEnglishRecordingRunsThroughFIRVADAndNeedle() async throws {
        let url = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let languages = Mutex<[String]>([])
        let result = try await transcriber().transcribe(.init(url: url, language: "it-IT", allowDownload: false)) {
            if case .whistleBatch(let batch) = $0 { languages.withLock { $0 += batch.languages } }
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
