import Foundation
import Synchronization
import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
import CassiniWhistle
@testable import Cassini

/// Cold imports must wait for installed Parakeet verification, independently of simulator memory reporting.
@MainActor final class ColdImportAdmissionTests: XCTestCase {
    func testInstalledParakeetPreventsTemporaryWhistleMemoryRejectionOfAutomaticImport() async throws {
        try await exercise(temporaryWhistleFailure: .memory)
    }

    func testInstalledParakeetDoesNotPinAutomaticImportToTemporaryRunnableWhistle() async throws {
        try await exercise(temporaryWhistleFailure: nil)
    }

    func testUnavailableExplicitWhistleWaitsForTheInstalledParakeetFallback() async throws {
        try await exercise(temporaryWhistleFailure: .model, preference: .whistle, bundleVerified: false)
    }

    func testExplicitWhistleReleasesStartupWithoutWaitingForParakeetVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-explicit-\(UUID())")
        let suite = "cassini.cold-explicit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("whistle", forKey: "speech.modelPreference")
        let entered = expectation(description: "background Parakeet verifier entered")
        let ready = expectation(description: "explicit Whistle startup completed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let verified = Mutex(false)
        let store = SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(),
            whistle: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                           pipelineAccepted: true, deviceAccepted: true),
            parakeetLinked: true, platform: .iOS26, physicalMemory: 6 << 30,
            availableMemory: { ParakeetMemory.beforeLoadBytes }, installed: { true },
            verified: { verified.withLock { $0 } },
            verify: { entered.fulfill(); release.wait(); verified.withLock { $0 = true }; return true },
            verifyBundle: { true })
        let graph = TestGraph(root: root, suite: suite, speechModels: store, modelRoot: root.appendingPathComponent("Models"))
        defer { graph.tearDown() }
        let published = expectation(description: "released background verification published")
        let previous = store.onChange
        var notified = false
        store.onChange = {
            previous()
            if store.installation == .verified && !notified { notified = true; published.fulfill() }
        }
        let start = Task { let report = await graph.graph.start(); ready.fulfill(); return report }
        await fulfillment(of: [entered, ready], timeout: 30) // Outer hang guard; verifier is still gated.
        XCTAssertTrue(graph.graph.startup.isReady)
        XCTAssertEqual(store.installation, .checking)
        XCTAssertEqual(store.selectedRecognizer(), .whistle)
        XCTAssertFalse(verified.withLock { $0 })
        release.signal()
        _ = await start.value
        await fulfillment(of: [published], timeout: 30)
    }

    func testStartupReleasesAfterFailedVerificationAndKeepsTheFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-failed-\(UUID())")
        let suite = "cassini.cold-failed.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let entered = expectation(description: "failing verifier entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(),
            whistle: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                           pipelineAccepted: true, deviceAccepted: true),
            parakeetLinked: true, platform: .iOS26, physicalMemory: 6 << 30,
            availableMemory: { ParakeetMemory.beforeLoadBytes }, installed: { true }, verified: { false },
            verify: { entered.fulfill(); release.wait(); throw CocoaError(.fileReadCorruptFile) }, verifyBundle: { true })
        let graph = TestGraph(root: root, suite: suite, speechModels: store, modelRoot: root.appendingPathComponent("Models"))
        defer { graph.tearDown() }
        let start = Task { await graph.graph.start() }
        await fulfillment(of: [entered], timeout: 30)
        XCTAssertFalse(graph.graph.startup.isReady)
        release.signal()
        let report = await start.value
        XCTAssertTrue(report.failed.isEmpty, "Failed model verification must not fail application startup")
        XCTAssertTrue(graph.graph.startup.isReady)
        XCTAssertEqual(store.installation, .unavailable)
        XCTAssertEqual(store.selectedRecognizer(), .whistle, "Failed integrity is never promoted to Parakeet")
    }

    func testMissingOrIncapableDevicesDoNotStartInstalledModelVerification() async throws {
        for (physicalMemory, installed) in [(UInt64(6) << 30, false), (UInt64(3) << 30, true)] {
            let suite = "cassini.cold-absent.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let calls = Mutex(0)
            let store = SpeechModelsStore(root: FileManager.default.temporaryDirectory, defaults: defaults,
                storage: FakeStorage(), whistle: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                                     pipelineAccepted: true, deviceAccepted: true),
                parakeetLinked: true, platform: .iOS26, physicalMemory: physicalMemory,
                installed: { installed }, verified: { false }, verify: { calls.withLock { $0 += 1 }; return true },
                verifyBundle: { true })
            await store.verifyInstalledSpeech()
            XCTAssertEqual(store.installation, .missing)
            XCTAssertEqual(calls.withLock { $0 }, 0)
        }
    }

    private func exercise(temporaryWhistleFailure: JobFailure?, preference: SpeechModelPreference = .parakeet,
                          bundleVerified: Bool = true) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-admission-\(UUID())")
        let suite = "cassini.cold-admission.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(preference.rawValue, forKey: "speech.modelPreference")
        defaults.set(NSNumber(value: 1), forKey: SettingsKeys.modelsConsentAt)
        let started = expectation(description: "installed model verification entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let checked = Mutex(false)
        let observations = AdmissionTrace()
        let acceptance = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                          pipelineAccepted: true, deviceAccepted: true)
        let models = SpeechModelsStore(root: root.appendingPathComponent("Models"), defaults: defaults,
            storage: FakeStorage(), whistle: acceptance, parakeetLinked: true, platform: .iOS26,
            physicalMemory: 6 << 30, availableMemory: { ParakeetMemory.beforeLoadBytes },
            installed: { true }, verified: { checked.withLock { $0 } }, verify: {
                started.fulfill()
                release.wait() // Event gate on utility worker, never a main-actor sleep or time assertion.
                checked.withLock { $0 = true }
                return true
            }, verifyBundle: { bundleVerified })
        let parakeet = AdmissionProbe(recognizer: .parakeet, failure: nil, observations: observations)
        let whistle = AdmissionProbe(recognizer: .whistle, failure: temporaryWhistleFailure, observations: observations)
        let speech = RoutedTranscriber(legacy: parakeet, candidates: [parakeet, whistle]) { models.selectedRecognizer() }
        let graph = TestGraph(root: root, suite: suite, transcriber: speech, speechModels: models,
                              modelRoot: root.appendingPathComponent("Models"),
                              audio: FakeAudioProcessing(duration: 16.627, opensAnyFile: true))
        defer { graph.tearDown() }
        graph.graph.settings.queueHold = .user // Admission persists jobs but never runs fake/native inference.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("Synthetic English cold admission.wav")
        try Data("English audio stand-in, decoded only by FakeAudioProcessing".utf8).write(to: audio)
        let start = Task { await graph.graph.start() }
        let imported = graph.graph.imports.importFile(audio, opensNote: true)
        await fulfillment(of: [started], timeout: 30)
        XCTAssertEqual(models.installation, .checking)
        XCTAssertEqual(models.selectedRecognizer(), bundleVerified ? .whistle : .appleSpeech,
                       "Unchecked Parakeet weights cannot be selected yet")
        let prematureReady = graph.graph.startup.isReady
        var beforeRelease: [String: Any] = [:]
        if prematureReady {
            // On unfixed main, complete the import while the verifier remains gated to diagnose the exact loss.
            if let outcome = await imported.value, case .created(let id) = outcome {
                beforeRelease = ["noteStatus": graph.graph.library.note(id).map { String(describing: $0.status) } ?? "missing",
                                 "jobRecognizer": graph.graph.processing.state.jobs[id]?.recognizer ?? "none"]
            }
        }
        XCTAssertFalse(prematureReady, "Startup released import/recording admission before installed-model verification")
        release.signal()
        _ = await start.value
        guard let outcome = await imported.value, case .created(let id) = outcome else {
            return XCTFail("Expected a new automatic audio import")
        }
        XCTAssertEqual(models.installation, .verified)
        XCTAssertEqual(models.selectedRecognizer(), .parakeet)
        XCTAssertEqual(graph.graph.processing.state.jobs[id]?.recognizer, "parakeet")
        XCTAssertEqual(graph.graph.processing.state.jobs[id]?.state, .queued)
        let storedNote = await graph.graph.library.noteStore?.note(id)
        XCTAssertEqual(storedNote?.status, .queued)
        let calls = observations.values
        let diagnostic: [String: Any] = ["scenario": temporaryWhistleFailure == nil ? "runnableWhistle" : "whistleMemoryRejected",
            "fakeAdapters": true, "simulatorMemoryNotConsulted": true, "startupReleasedBeforeVerification": prematureReady,
            "beforeVerifierRelease": beforeRelease, "unavailabilityChecked": calls,
            "finalJobRecognizer": graph.graph.processing.state.jobs[id]?.recognizer ?? "none"]
        let bytes = try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = "cold-import-admission-\(temporaryWhistleFailure == nil ? "runnable" : "memory")"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(calls.contains("whistle"), "Cold admission consulted the temporary fallback instead of verified preferred Parakeet")
    }
}

private struct AdmissionProbe: Transcribing {
    let recognizer: SpeechRecognizer
    let failure: JobFailure?
    let observations: AdmissionTrace
    func unavailability(locale: Locale) async -> JobFailure? {
        observations.record(recognizer.rawValue)
        return failure
    }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .ready }
    func speechLanguages() async -> [SpeechLanguage] { [] }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        throw TranscriptionError.failed(.model) // Queue hold must prevent decoding in this admission-only test.
    }
}

private final class AdmissionTrace: Sendable {
    private let items = Mutex<[String]>([])
    func record(_ value: String) { items.withLock { $0.append(value) } }
    var values: [String] { items.withLock { $0 } }
}
