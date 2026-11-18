import Darwin
import XCTest
import CassiniEngine
import CassiniNotebook
import CassiniSherpa
import CassiniWhistle

final class OnnxRuntimePrivacyTests: XCTestCase {
    override func tearDown() {
        OnnxRuntimePrivacy.ensureTelemetryDisabled()
        super.tearDown()
    }

    func testAppLaunchSetsTelemetryOptOut() {
        XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
        XCTAssertTrue(OnnxRuntimePrivacy.isTelemetryDisabled)
    }

    func testSherpaFirstWithoutWhistleSetsTelemetryOptOutFromMissingAndZero() throws {
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without the native runtime")
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).onnx")
        let actions: [() -> Void] = [
            { _ = try? ParakeetDecoder(files: ParakeetFiles(directory: missing)) },
            { _ = try? SileroDetector(config: SileroConfig(model: missing)) },
            { _ = try? SortformerStream(model: missing) },
            { _ = try? SortformerStream.turns(PcmAudio([0], sampleRate: 16_000), model: missing) },
            { _ = try? VoiceprintExtractor.compute(model: missing, audio: PcmAudio([0], sampleRate: 16_000),
                                                   windows: ["a": [PrintWindow(0, 1)]]) {} }
        ]
        for action in actions {
            for initial in [String?.none, "0"] {
                if let initial { setenv(OnnxRuntimePrivacy.environmentKey, initial, 1) }
                else { unsetenv(OnnxRuntimePrivacy.environmentKey) }
                XCTAssertFalse(OnnxRuntimePrivacy.isTelemetryDisabled)
                action()
                XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
            }
        }
    }

    func testWhistleVADAndRuntimePreserveTelemetryAndCAPIOptOut() async throws {
        let vadModel = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Whistle/silero-vad-6.2.1.onnx"))
        for initial in [String?.none, "0"] {
            if let initial { setenv(OnnxRuntimePrivacy.environmentKey, initial, 1) }
            else { unsetenv(OnnxRuntimePrivacy.environmentKey) }
            let vad = try WhistleVAD(model: vadModel)
            XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
            let probability = try vad.probability([Float](repeating: 0, count: 512))
            XCTAssertTrue((0...1).contains(probability))
        }

        #if arch(arm64)
        let verified = await WhistleRuntime.verifyBundle(.main)
        XCTAssertTrue(verified)
        let laboratory = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                           pipelineAccepted: true, deviceAccepted: true)
        for initial in [String?.none, "0"] {
            if let initial { setenv(OnnxRuntimePrivacy.environmentKey, initial, 1) }
            else { unsetenv(OnnxRuntimePrivacy.environmentKey) }
            try await WhistleRuntime.shared.prepare(acceptance: laboratory)
            XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
            await WhistleRuntime.shared.close()
        }
        #endif
    }

    func testBothEngineOrdersKeepTelemetryOptOut() async throws {
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without the native runtime")
        let vadModel = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Whistle/silero-vad-6.2.1.onnx"))
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).onnx")

        // Order 1: Sherpa first, then Whistle.
        setenv(OnnxRuntimePrivacy.environmentKey, "0", 1)
        _ = try? ParakeetDecoder(files: ParakeetFiles(directory: missing))
        XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
        let vad1 = try WhistleVAD(model: vadModel)
        XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
        _ = try vad1.probability([Float](repeating: 0, count: 512))

        // Order 2: Whistle first, then Sherpa.
        unsetenv(OnnxRuntimePrivacy.environmentKey)
        let vad2 = try WhistleVAD(model: vadModel)
        XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
        _ = try vad2.probability([Float](repeating: 0, count: 512))
        _ = try? SileroDetector(config: SileroConfig(model: missing))
        XCTAssertEqual(OnnxRuntimePrivacy.currentValue, "1")
    }
}
