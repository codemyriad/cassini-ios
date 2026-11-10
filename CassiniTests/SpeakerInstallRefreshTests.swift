import XCTest
import Observation
import Synchronization
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
import CassiniWhistle
@testable import Cassini

/// Exercises the production installer-idle callback and AppGraph's model refresh binding, without the model host,
/// inference, personal files, or a manual refresh after the shared install.
@MainActor final class SpeakerInstallRefreshTests: XCTestCase {
    func testSharedInstallerSuccessClearsTheStandaloneSpeakerFailureWhileSpeechVerificationIsBusy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "cassini.speaker-refresh.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let modelRoot = root.appendingPathComponent("Models", isDirectory: true)
        let verificationStarted = expectation(description: "speech verification is held")
        let releaseVerification = DispatchSemaphore(value: 0)
        defer { releaseVerification.signal() }
        let speech = SpeechModelsStore(root: modelRoot, defaults: defaults, storage: FakeStorage(),
            whistle: WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                      pipelineAccepted: true, deviceAccepted: true),
            parakeetLinked: true, physicalMemory: 6 << 30, installed: { true }, verified: { false },
            verify: { verificationStarted.fulfill(); releaseVerification.wait(); return false })
        let fetcher = SpeakerRefreshFetcher()
        let repository = ModelRepository(root: modelRoot,
            consent: SettingsStore(defaults: defaults, clock: FakeClock(), defaultLanguage: "en-US"), fetcher: fetcher)
        let installer = PinnedModelInstaller(models: repository, storage: FakeStorage(), online: { true },
            onChange: { status in
                Task { @MainActor in AppEnvironment.modelInstallerChanged(status, speechModels: speech) }
            })
        let analyzer = SpeakerRefreshAnalyzer(models: SpeakerModels(repository: repository, installer: installer))
        let test = TestGraph(root: root, suite: suite, analyzer: analyzer, speechModels: speech, modelRoot: modelRoot)
        defer { test.tearDown() }
        let installs = test.graph.processing.models
        speech.refresh()
        await fulfillment(of: [verificationStarted], timeout: 15)
        XCTAssertEqual(speech.installation, .checking)
        await installs.refresh() // Drain startup reads before either install; no refresh follows shared completion.
        let standaloneEnded = expectation(description: "standalone caller released background time")
        test.background.onEnd = { _ in standaloneEnded.fulfill() }
        installs.install([.speakers])
        await fulfillment(of: [standaloneEnded], timeout: 15)
        XCTAssertFalse(installs.isInstalling)
        XCTAssertEqual(installs.download?.failure, .interrupted)
        XCTAssertEqual(installs.status(of: .speakers), .failed(.interrupted))

        // A different caller now completes the shared models, without ending a job or refreshing the stores itself.
        fetcher.fail = false
        _ = try await installer.install(SpeakerModels.parts, granted: true)
        await observe("the installer-idle callback cleared the obsolete failure") {
            installs.status(of: .speakers) == .ready && installs.download == nil
        }
        XCTAssertEqual(installs.status(of: .voices), .ready)
        XCTAssertNil(installs.failures[.speakers])
        XCTAssertEqual(speech.installation, .checking, "the refresh cannot depend on the blocked speech verifier")
        XCTAssertFalse(Notices.library(NoticeFacts(download: installs.download), LibraryFacts()).contains { $0.kind.isDownloadFailure })
    }

    private func observe(_ message: String, condition: @escaping @MainActor @Sendable () -> Bool) async {
        let satisfied = expectation(description: message)
        let observer = Task { @MainActor in
            for await value in Observations({ condition() }) where value {
                satisfied.fulfill()
                return
            }
        }
        defer { observer.cancel() }
        await fulfillment(of: [satisfied], timeout: 15)
    }
}

private final class SpeakerRefreshFetcher: ModelFetching {
    private let failing = Mutex(true)
    var fail: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func fetch(_ model: ModelDescriptor, into directory: URL,
               progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        if fail { throw ModelError(.modelDownload) }
        // Sparse files exercise the real installation/commit and readiness checks without loading model weights.
        for artifact in model.artifacts {
            let file = directory.appendingPathComponent(artifact.name)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            try output.truncate(atOffset: UInt64(artifact.size))
        }
        try "Test model notices".write(to: directory.appendingPathComponent(ModelDescriptor.noticeFile), atomically: true, encoding: .utf8)
        progress(model.downloadBytes, true)
    }
}

private struct SpeakerRefreshAnalyzer: SpeakerAnalyzing {
    let models: SpeakerModels
    var modelInstallBytes: Int64 { models.installBytes }
    func modelStatus() async -> ModelPartStatus { models.status(linked: true) }
    func refreshModelStatus() async -> ModelPartStatus { await models.refresh(linked: true) }
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        try await models.install(progress: progress)
    }
    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        SpeakerAnalysis(turns: [], prints: [])
    }
}
