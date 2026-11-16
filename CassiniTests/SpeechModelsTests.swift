import XCTest
import Synchronization
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
import CassiniWhistle
@testable import Cassini

@MainActor final class SpeechModelsTests: XCTestCase {
    private struct Files: Sendable { var installed = true; var verified = false }
    private let accepted = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                            pipelineAccepted: true, deviceAccepted: true)

    func testSettingsSelectionReadsPublishedFactsWithoutProbingFiles() throws {
        let suite = "cassini.settings-models.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probes = Mutex(0)
        let store = SpeechModelsStore(root: FileManager.default.temporaryDirectory, defaults: defaults,
            storage: FakeStorage(), whistle: accepted, parakeetLinked: true, platform: .iOS26,
            physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { probes.withLock { $0 += 1 }; return true },
            verified: { probes.withLock { $0 += 1 }; return true }, verify: { true })
        XCTAssertEqual(store.displayRecognizer, .whistle)
        XCTAssertFalse(store.canChooseParakeet)
        XCTAssertEqual(probes.withLock { $0 }, 0)
        store.refresh()
        let reads = probes.withLock { $0 }
        XCTAssertEqual(store.displayRecognizer, .parakeet)
        XCTAssertTrue(store.canChooseParakeet)
        store.choose(.whistle)
        XCTAssertEqual(store.displayRecognizer, .whistle)
        store.choose(.parakeet)
        XCTAssertEqual(store.displayRecognizer, .parakeet)
        XCTAssertEqual(probes.withLock { $0 }, reads, "Rendering and choosing use published facts")
    }

    func testVerificationPromotesOnlyNewDefaultsAndAnnouncesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "cassini.d78.\(UUID())", defaults: UserDefaults
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = Mutex(Files()), started = expectation(description: "hash check started"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(), whistle: accepted,
            parakeetLinked: true, platform: .iOS26, physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { files.withLock { $0.installed } }, verified: { files.withLock { $0.verified } },
            verify: { started.fulfill(); release.wait(); return files.withLock { $0.verified } })
        let finished = expectation(description: "verification published")
        var published = false
        store.onChange = {
            if store.installation == .verified && !published { published = true; finished.fulfill() }
        }
        store.refresh()
        XCTAssertEqual(store.installation, .checking)
        await fulfillment(of: [started], timeout: 30)
        XCTAssertEqual(store.selectedRecognizer(), .whistle, "File presence never promotes unchecked weights")
        XCTAssertFalse(store.shows(.settings), "No download suggestion while files are being checked")
        files.withLock { $0.verified = true }
        XCTAssertEqual(store.selectedRecognizer(), .parakeet, "Published verifier result applies without relaunch/main-actor lag")
        release.signal()
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertTrue(store.promotionVisible)
        store.markPromotionShown(); store.dismissPromotion()
        let reopened = SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(), whistle: accepted,
            parakeetLinked: true, platform: .iOS26, physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { true }, verified: { true }, verify: { true })
        reopened.refresh()
        XCTAssertFalse(reopened.promotionVisible)
        reopened.choose(.whistle)
        XCTAssertEqual(reopened.selectedRecognizer(), .whistle, "Whistle remains an explicit fallback choice")
    }

    func testA12NeverSuggestsOrOpensAParakeetDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "cassini.d78.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let checks = Mutex(0)
        let store = SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(), whistle: accepted,
            parakeetLinked: true, platform: .iOS26, physicalMemory: 3 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { true }, verified: { false }, verify: { checks.withLock { $0 += 1 }; return true })
        let graph = TestGraph(root: root, suite: suite, speechModels: store, modelRoot: root)
        defer { graph.tearDown() }
        store.refresh()
        store.completed(Job(noteID: UUID(), seq: 1, kind: .transcribe, enqueuedAt: Date(), recognizer: "whistle"), outcome: .done)
        XCTAssertEqual(store.selectedRecognizer(), .whistle)
        XCTAssertFalse(store.shows(.settings)); XCTAssertFalse(store.shows(.afterWhistle))
        XCTAssertNil(graph.graph.processing.parakeetDownload)
        XCTAssertEqual(checks.withLock { $0 }, 0)
    }

    func testSpeechUpgradePlanDoesNotSmuggleInTheSpeakerModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "cassini.d78.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(), whistle: accepted,
            parakeetLinked: true, platform: .iOS26, physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { false }, verified: { false }, verify: { false })
        let whistle = FakeTranscriber(.returns([], total: 1), recognizer: .whistle)
        let parakeet = FakeTranscriber(.returns([], total: 1), status: .notDownloaded, recognizer: .parakeet)
        let test = TestGraph(root: root, suite: suite, transcriber: whistle, speechModels: store,
                             downloadTranscriber: parakeet, modelRoot: root)
        defer { test.tearDown() }
        let ports = try XCTUnwrap(test.graph.processing.parakeetDownload)
        let plan = await ports.plan(for: nil)
        XCTAssertEqual(plan.missing, [.speech])
        XCTAssertEqual(plan.totalDownloadBytes, store.policy.downloadPlan.totalBytes)
        XCTAssertEqual(plan.requiredFreeBytes, store.policy.downloadPlan.requiredFreeBytes)
        XCTAssertTrue(store.shows(.settings))
        XCTAssertFalse(store.shows(.afterWhistle))
        store.completed(Job(noteID: UUID(), seq: 1, kind: .transcribe, enqueuedAt: Date(), recognizer: "whistle"), outcome: .done)
        XCTAssertTrue(store.shows(.afterWhistle))
        store.dismissSuggestion()
        XCTAssertFalse(store.shows(.settings)); XCTAssertFalse(store.shows(.afterWhistle))
    }
}
