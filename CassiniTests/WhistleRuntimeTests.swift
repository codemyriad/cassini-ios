import XCTest
import CryptoKit
import AVFoundation
import CassiniWhistle

/// Mandatory on arm64: actually enter the engine embedded in the production app, without audio I/O/network.
/// This checks bundle closure and loader lifetime, not desktop pipeline parity or device acceptance.
final class WhistleRuntimeTests: XCTestCase {
    func testPinnedPrivateBundleLoadsThroughTheGuardedCAPI() async throws {
        #if arch(arm64)
        let bundle = Bundle.main
        let verified = await WhistleRuntime.verifyBundle(bundle)
        XCTAssertTrue(verified, "production asset/path gate accepts the app-bundled runtime before guarded loading")
        let root = try XCTUnwrap(bundle.resourceURL?.appendingPathComponent("Whistle"))
        let weights = try Data(contentsOf: root.appendingPathComponent("whistle.cact"), options: .mappedIfSafe)
        XCTAssertEqual(weights.count, 16_919_407)
        XCTAssertEqual(SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined(), WhistleRuntime.modelSHA256)
        // Explicit test acceptance permits this laboratory C API call only; no production rollout flag is set.
        let laboratory = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                          pipelineAccepted: true, deviceAccepted: true)
        let fixtures = try XCTUnwrap(bundle.resourceURL?.appendingPathComponent("WhistleTests"))
        struct Golden: Decodable { var modelSha256: String; var inputSha256: String; var samples: Int; var result: WhistleResult }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: fixtures.appendingPathComponent("golden.json")))
        XCTAssertEqual(golden.modelSha256, WhistleRuntime.modelSHA256)
        let file = try AVAudioFile(forReading: fixtures.appendingPathComponent("jfk.wav"))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let pcm = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData).pointee, count: Int(buffer.frameLength)))
        XCTAssertEqual(pcm.count, golden.samples)
        let hash = pcm.withUnsafeBufferPointer { SHA256.hash(data: Data(buffer: $0)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hash, golden.inputSha256, "same raw PCM as the frozen Mac baseline, before native entry")
        let result = try await WhistleRuntime.shared.transcribe(pcm, acceptance: laboratory)
        await WhistleRuntime.shared.close()
        XCTAssertEqual(result.text, golden.result.text)
        XCTAssertEqual(result.language, golden.result.language)
        XCTAssertEqual(result.words.map(\.word), golden.result.words.map(\.word))
        for (actual, expected) in zip(result.words, golden.result.words) {
            XCTAssertLessThanOrEqual(abs(actual.start - expected.start), 0.080001)
            XCTAssertLessThanOrEqual(abs(actual.end - expected.end), 0.080001)
        }
        XCTAssertFalse(WhistleCapability.pending(bundleVerified: true).available, "a successful smoke test cannot accept a device class")
        #else
        throw XCTSkip("No published pinned x86_64 simulator archive; capability is unavailable")
        #endif
    }
}
