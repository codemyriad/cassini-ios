import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
import CassiniSherpa
import CassiniWhistle
@testable import Cassini

/// The app's composition over both values of the platform facts: the iOS 26 facts keep today's choices, and the iOS 18
/// facts (no Apple speech, no continued processing) never build Apple's adapter or ask for continued processing.
@MainActor final class PlatformCompositionTests: XCTestCase {
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

    func testTheLiveAppHasTheIOS26Facts() {
        XCTAssertEqual(LivePlatform.facts, .iOS26)
        XCTAssertTrue(LivePlatform.whistleCPUSupported)
        XCTAssertEqual(LivePlatform.whistleOperatingSystemSupported,
                       ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= WhistleCapability.minimumOperatingSystemMajor)
    }

    /// A device that cannot hold Parakeet gets Apple's adapter on iOS 26 and the candidate that refuses on iOS 18.
    func testASmallDeviceWithoutAppleSpeechGetsTheUnavailableCandidate() async {
        let models = PinnedModels(root: root, defaults: UserDefaults(suiteName: suite)!, storage: FileSystemStorageProbe())
        XCTAssertTrue(AppEnvironment.speechTranscriber(models: models, physicalMemory: 4 << 30, platform: .iOS26) is AppleSpeechTranscriber)
        let unavailable = AppEnvironment.speechTranscriber(models: models, physicalMemory: 4 << 30, platform: .iOS18)
        XCTAssertTrue(unavailable is UnavailableSpeechTranscriber)
        let failure = await unavailable.unavailability(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(failure, .model)
        if SherpaRuntime.isLinked {
            XCTAssertEqual(AppEnvironment.speechTranscriber(models: models, physicalMemory: 8 << 30, platform: .iOS18).recognizer,
                           .parakeet, "a capable device keeps Parakeet on either system")
        }
    }

    /// Without Whistle and a verified Parakeet, new jobs go to Apple speech on iOS 26, to Parakeet on a capable iOS 18
    /// device (Transcribe then asks for its download), and nowhere on a small one.
    func testTheStoreFallsBackToParakeetOrNothingWithoutAppleSpeech() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let unavailable = WhistleCapability(arm64: true, operatingSystemSupported: true, cpuSupported: false,
                                            bundleVerified: true, pipelineAccepted: true, deviceAccepted: true)
        func store(_ platform: PlatformFacts, memory: UInt64) -> SpeechModelsStore {
            SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(), whistle: unavailable,
                parakeetLinked: true, platform: platform, physicalMemory: memory,
                availableMemory: { ParakeetMemory.beforeLoadBytes }, installed: { false }, verified: { false }, verify: { false })
        }
        XCTAssertEqual(store(.iOS26, memory: 6 << 30).selectedRecognizer(), .appleSpeech)
        XCTAssertEqual(store(.iOS26, memory: 3 << 30).selectedRecognizer(), .appleSpeech)
        XCTAssertEqual(store(.iOS18, memory: 6 << 30).selectedRecognizer(), .parakeet)
        XCTAssertEqual(store(.iOS18, memory: 3 << 30).selectedRecognizer(), .appleSpeech,
                       "the Apple identity reaches the unavailable candidate")
    }

    /// Settings offers Apple's speech language only where the system has Apple speech.
    func testSettingsFollowsThePlatform() async {
        for platform in [PlatformFacts.iOS26, .iOS18] {
            let test = TestGraph(transcriber: AppEnvironment.appleSpeechCandidate(platform: platform), platform: platform)
            defer { test.tearDown() }
            XCTAssertEqual(test.graph.settingsPorts.platform, platform)
            let model = SettingsModel(ports: test.graph.settingsPorts)
            XCTAssertEqual(model.showsSpeechLanguage, platform.appleSpeech)
            XCTAssertEqual(test.graph.settingsPorts.size(of: .speech), platform.appleSpeech ? .managedBySystem : .noModel)
        }
    }
}
