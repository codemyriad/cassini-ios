import XCTest
import Observation
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
    func testEachSettingsRowActuallyRequestsOnlyItsConsentedInstallGroup() async throws {
        for part in ModelPart.allCases {
            let requested = expectation(description: "\(part) installer received the request")
            let recorder = FakeModelInstallRecorder(onRequest: { _ in requested.fulfill() })
            let speech = FakeTranscriber(.returns([], total: 1), status: .notDownloaded, recognizer: .parakeet,
                                         installRecorder: recorder)
            let test = TestGraph(transcriber: speech, analyzer: FakeAnalyzer(modelIdentity: nil, installRecorder: recorder))
            defer { test.tearDown() }
            await test.graph.start()
            let settings = SettingsModel(ports: test.graph.settingsPorts)
            await settings.appeared()
            var route: Route?
            settings.onEffect = { if case .open(let opened) = $0 { route = opened } }
            settings.openModel(part)
            guard case .modelDownload(let noteID, let selected) = try XCTUnwrap(route) else {
                XCTFail("Settings did not open the model download"); continue
            }
            let ports = try XCTUnwrap(test.graph.processing.modelDownload)
            let model = ModelDownloadModel(noteID: noteID, ports: ports, part: selected)
            await model.load()
            await model.download()
            await fulfillment(of: [requested], timeout: 15)
            await observeInstallEnd(test.graph.processing.models)
            let expected: [ModelPart] = part == .speech ? [.speech] : [.speakers]
            XCTAssertEqual(recorder.snapshot.requested, expected, "No unrelated or duplicate installer calls")
            XCTAssertEqual(recorder.snapshot.completed, expected)
            XCTAssertEqual(test.graph.settings.downloadsAllowed, part == .speech)
            XCTAssertEqual(test.graph.settings.speakerDownloadsAllowed, part != .speech)
        }
    }

    private func observeInstallEnd(_ models: ModelInstalls) async {
        let ended = expectation(description: "the entire install queue completed its closing refresh")
        let observer = Task { @MainActor in
            let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            var next = changes.makeAsyncIterator()
            repeat {
                if withObservationTracking({ models.download == nil && !models.isInstalling }, onChange: { changed.yield() }) {
                    ended.fulfill()
                    return
                }
            } while await next.next() != nil
        }
        defer { observer.cancel() }
        await fulfillment(of: [ended], timeout: 15)
    }

}
