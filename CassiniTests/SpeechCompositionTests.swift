import XCTest
import UIKit
import Synchronization
import CassiniEngine
import CassiniNotebook
import CassiniInference
import CassiniSherpa
@testable import Cassini

/// `AppEnvironment.speechTranscriber` and `speakerAnalyzer`: Parakeet Ultra when the runtime is linked and the device
/// capable, installed or not, else Apple Speech (decision D2); speech and the speaker models share one installer.
@MainActor final class SpeechCompositionTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suite = "cassini.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func models(fetcher: (any ModelFetching)? = nil) -> PinnedModels {
        PinnedModels(root: root, defaults: UserDefaults(suiteName: suite)!, storage: FileSystemStorageProbe(),
                     fetcher: fetcher)
    }

    func testACapableDeviceUsesUltraBeforeItsModelIsInstalled() throws {
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without the native runtime")
        XCTAssertFalse(ModelCatalog.parakeet.ready(in: root))
        XCTAssertEqual(AppEnvironment.speechTranscriber(models: models(), physicalMemory: 8 << 30, platform: .iOS26).recognizer, .parakeet,
                       "the job downloads Ultra with consent")
    }

    /// What 4 GB devices report (3665 MiB an iPhone 13, 3854 MiB an iPhone 11) is enough for Ultra; what a 3 GB device
    /// can report at most (3072 MiB) is not.
    func testA4GBDeviceUsesUltraAndA3GBDeviceDoesNot() throws {
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without the native runtime")
        for mebibytes in [3665, 3854] as [UInt64] {
            XCTAssertEqual(AppEnvironment.speechTranscriber(models: models(), physicalMemory: mebibytes << 20, platform: .iOS18).recognizer,
                           .parakeet, "\(mebibytes) MiB")
        }
        XCTAssertNotEqual(AppEnvironment.speechTranscriber(models: models(), physicalMemory: 3072 << 20, platform: .iOS18).recognizer, .parakeet)
    }

    /// Over the system's own facts: Apple's adapter where the system has Apple speech, else the candidate in Apple's
    /// slot that refuses every job (iOS 18).
    func testA3GBDeviceUsesTheCapabilityCheckedAppleCandidate() {
        let transcriber = AppEnvironment.speechTranscriber(models: models(), physicalMemory: 3 << 30, platform: LivePlatform.facts)
        XCTAssertEqual(transcriber.recognizer, .appleSpeech, "the adapter checks hardware, locale and assets before choosing Apple")
        if #available(iOS 26.0, *) {
            XCTAssertTrue(transcriber is AppleSpeechTranscriber)
        } else {
            XCTAssertTrue(transcriber is UnavailableSpeechTranscriber)
        }
    }

    /// The speech download and the speaker models go through one installer: while Ultra downloads, the installer
    /// shows that install to the speaker side, and it stops when its only caller leaves.
    func testSpeechAndTheSpeakerModelsShareOneInstaller() async throws {
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without the native runtime")
        UserDefaults(suiteName: suite)!.set(NSNumber(value: 1), forKey: SettingsKeys.modelsConsentAt)
        let fetcher = HeldFetcher()
        let models = models(fetcher: fetcher)
        let transcriber = AppEnvironment.speechTranscriber(models: models, physicalMemory: 8 << 30, platform: .iOS26)
        let analyzer = AppEnvironment.speakerAnalyzer(models: models)
        XCTAssertTrue(analyzer.models.installer === models.installer)

        let download = Task { try await transcriber.installAssets(locale: Locale(identifier: "it-IT")) { _ in } }
        // The installer shows the install before it asks the host for Ultra: wait for both.
        try await waitUntil("the speech download never reached the shared installer and the host") {
            guard case .installing(let parts, _, _) = models.installer.status, parts == [.speech] else { return false }
            return !fetcher.fetched.isEmpty
        }
        XCTAssertEqual(fetcher.fetched, [ModelCatalog.parakeet.pin])
        if case .installing = analyzer.models.installer.status {} else { XCTFail("the speaker side sees the install") }

        download.cancel()
        do {
            try await download.value
            XCTFail("the cancelled download returned")
        } catch is CancellationError {}
        try await waitUntil("the installer never went idle") { models.installer.status == .idle }
        XCTAssertEqual(fetcher.fetched, [ModelCatalog.parakeet.pin], "nothing else was fetched")
    }

    /// D54: the model downloads name the app's marketing version, the iOS version as iOS writes it, and the build.
    func testTheModelDownloadsUserAgentComesFromTheBundle() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertEqual(PinnedModels.userAgent, "CassiniTalk/\(version) (iOS \(UIDevice.current.systemVersion); build \(build))")
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A model host that never answers: each fetch waits until it is cancelled.
private final class HeldFetcher: ModelFetching {
    private let list = Mutex<[String]>([])
    var fetched: [String] { list.withLock { $0 } }

    func fetch(_ model: ModelDescriptor, into directory: URL,
               progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        list.withLock { $0.append(model.pin) }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
