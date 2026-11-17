import XCTest
import Synchronization
import Observation
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

    func testSettingsSelectionReadsPublishedFactsWithoutProbingFiles() async throws {
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
        await store.settleVerification()
        let reads = probes.withLock { $0 }
        XCTAssertEqual(store.displayRecognizer, .parakeet)
        XCTAssertTrue(store.canChooseParakeet)
        store.choose(.whistle)
        XCTAssertEqual(store.displayRecognizer, .whistle)
        store.choose(.parakeet)
        XCTAssertEqual(store.displayRecognizer, .parakeet)
        XCTAssertEqual(probes.withLock { $0 }, reads, "Rendering and choosing use published facts")
    }

    func testRoutineRefreshNeverFlashesCheckingOrDismissesThePromotion() async throws {
        for installed in [false, true] {
            let suite = "cassini.precheck.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SpeechModelsStore(root: FileManager.default.temporaryDirectory, defaults: defaults,
                storage: FakeStorage(), whistle: accepted, parakeetLinked: true, platform: .iOS26,
                physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
                installed: { installed }, verified: { installed }, verify: { XCTFail("No hashing needed"); return false })
            await store.verifyInstalledSpeech()
            XCTAssertEqual(store.promotionVisible, installed)
            if installed { store.markPromotionShown() } // The visible banner's .task has run; it must stay visible.
            var states: [ParakeetInstallation] = [], promotions: [Bool] = []
            store.onChange = { states.append(store.installation); promotions.append(store.promotionVisible) }
            for _ in 0..<3 {
                store.refresh()
                XCTAssertEqual(store.displayRecognizer, installed ? .parakeet : .whistle)
                await store.settleVerification()
            }
            XCTAssertEqual(states, Array(repeating: installed ? .verified : .missing, count: 3))
            XCTAssertEqual(promotions, Array(repeating: installed, count: 3))
        }
    }

    func testAnInstallSupersedesAFilePrecheckAndKeepsItsProgressUntilIdle() async throws {
        for finishesDuringPrecheck in [false, true] {
            let suite = "cassini.install-precheck.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let started = expectation(description: "precheck started"), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let calls = Mutex(0), files = Mutex(false)
            let store = SpeechModelsStore(root: FileManager.default.temporaryDirectory, defaults: defaults,
                storage: FakeStorage(), whistle: accepted, parakeetLinked: true, platform: .iOS26,
                physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
                installed: {
                    let first = calls.withLock { $0 += 1; return $0 == 1 }
                    if first { started.fulfill(); release.wait(); return false }
                    return files.withLock { $0 }
                }, verified: { files.withLock { $0 } }, verify: { XCTFail("No hashing needed"); return false })
            store.refresh()
            await fulfillment(of: [started], timeout: 30)
            store.installerChanged(.installing(parts: [.speech], progress: nil, waiters: 1))
            var states: [ParakeetInstallation] = []
            store.onChange = { states.append(store.installation) }
            if finishesDuringPrecheck {
                files.withLock { $0 = true }
                store.installerChanged(.idle) // The pending precheck must be replaced once it returns.
            }
            release.signal()
            await store.settleVerification()
            if finishesDuringPrecheck {
                XCTAssertEqual(states, [.verified])
                XCTAssertEqual(calls.withLock { $0 }, 2)
                continue
            }
            store.refresh()
            await store.settleVerification()
            XCTAssertEqual(store.installation, .installing)
            XCTAssertEqual(calls.withLock { $0 }, 1, "An active install is never probed by a Settings refresh")
            XCTAssertTrue(states.isEmpty, "The stale missing result must not replace download progress")
            files.withLock { $0 = true }
            store.installerChanged(.idle)
            await store.settleVerification()
            XCTAssertEqual(states, [.verified])
            XCTAssertEqual(store.displayRecognizer, .parakeet)
        }
    }

    func testTransientVerificationFailureCanRetryWithoutDownloadingAndNeverProbesOnMain() async throws {
        let suite = "cassini.retry.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checked = Mutex(false), attempts = Mutex(0), mainProbes = Mutex(0)
        let store = SpeechModelsStore(root: FileManager.default.temporaryDirectory, defaults: defaults,
            storage: FakeStorage(), whistle: accepted, parakeetLinked: true, platform: .iOS26,
            physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { if Thread.isMainThread { mainProbes.withLock { $0 += 1 } }; return true },
            verified: { if Thread.isMainThread { mainProbes.withLock { $0 += 1 } }; return checked.withLock { $0 } },
            verify: {
                let attempt = attempts.withLock { $0 += 1; return $0 }
                if attempt == 1 { throw CocoaError(.fileReadUnknown) }
                checked.withLock { $0 = true }; return true
            })
        store.refresh()
        await store.settleVerification()
        XCTAssertEqual(store.installation, .unavailable)
        store.refresh()
        await store.settleVerification()
        XCTAssertEqual(store.installation, .verified)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(mainProbes.withLock { $0 }, 0)
    }

    func testDelayedWhistleVerificationInvalidatesSettingsWhileParakeetIsStillChecking() async throws {
        let suite = "cassini.bundle.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var cold = accepted; cold.bundleVerified = false
        let bundle = AsyncStream<Bool>.makeStream()
        let hashing = expectation(description: "Parakeet hashing"), release = DispatchSemaphore(value: 0)
        defer { release.signal(); bundle.continuation.finish() }
        let store = SpeechModelsStore(root: FileManager.default.temporaryDirectory, defaults: defaults,
            storage: FakeStorage(), whistle: cold, parakeetLinked: true, platform: .iOS26,
            physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { true }, verified: { false }, verify: { hashing.fulfill(); release.wait(); return false },
            verifyBundle: { for await value in bundle.stream { return value }; return false })
        XCTAssertEqual(store.displayRecognizer, .appleSpeech, "Uninstalled Parakeet is not the active answer")
        store.refresh()
        await fulfillment(of: [hashing], timeout: 30)
        let changed = expectation(description: "Whistle availability observed")
        withObservationTracking {
            XCTAssertFalse(store.whistleAvailable)
            XCTAssertEqual(store.displayRecognizer, .appleSpeech)
        } onChange: { changed.fulfill() }
        let verification = Task { await store.verifyBundledSpeech() }
        bundle.continuation.yield(true)
        await verification.value
        await fulfillment(of: [changed], timeout: 30)
        XCTAssertTrue(store.whistleAvailable)
        XCTAssertEqual(store.displayRecognizer, .whistle)
        XCTAssertEqual(store.installation, .checking)
        release.signal()
        await store.settleVerification()
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
        await fulfillment(of: [started], timeout: 30)
        XCTAssertEqual(store.installation, .checking)
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
        await reopened.settleVerification()
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
