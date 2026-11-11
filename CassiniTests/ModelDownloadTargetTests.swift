import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class ModelDownloadTargetTests: XCTestCase {
    func testSettingsPlansKeepSpeechAndTheSpeakerBundleSeparate() async throws {
        let speech = FakeTranscriber(.returns([], total: 1), status: .notDownloaded, recognizer: .parakeet)
        let test = TestGraph(transcriber: speech, analyzer: FakeAnalyzer(modelIdentity: nil))
        defer { test.tearDown() }
        let ports = try XCTUnwrap(test.graph.processing.modelDownload)
        for part in ModelPart.allCases {
            let plan = await ports.plan(for: nil, part: part)
            let expected: [ModelPart] = part == .speech ? [.speech] : [.speakers]
            XCTAssertEqual(plan.missing, expected)
            XCTAssertEqual(Set(plan.downloadBytes.keys), Set(expected))
            XCTAssertEqual(plan.totalDownloadBytes, ModelDownloadPlan.fullDownloadBytes(part))
        }
    }
}
