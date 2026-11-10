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

    /// The live facts are the system's: Apple speech and continued processing exactly where iOS 26's APIs are.
    func testTheLiveFactsFollowTheSystem() {
        if #available(iOS 26.0, *) {
            XCTAssertEqual(LivePlatform.facts, .iOS26)
        } else {
            XCTAssertEqual(LivePlatform.facts, .iOS18)
        }
        XCTAssertTrue(LivePlatform.whistleCPUSupported)
        XCTAssertEqual(LivePlatform.whistleOperatingSystemSupported,
                       ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= WhistleCapability.minimumOperatingSystemMajor)
    }

    /// Apple's adapter is built exactly where the facts say the system has Apple speech, and the system has it.
    func testTheAppleCandidateFollowsTheFactsAndTheSystem() {
        for platform in [LivePlatform.facts, .iOS26, .iOS18] {
            let candidate = AppEnvironment.appleSpeechCandidate(platform: platform)
            XCTAssertEqual(isApple(candidate), platform.appleSpeech && LivePlatform.facts.appleSpeech, "\(platform)")
            XCTAssertEqual(candidate is UnavailableSpeechTranscriber, !isApple(candidate), "\(platform)")
        }
    }

    /// A device that cannot hold Parakeet gets Apple's adapter on iOS 26 and the candidate that refuses on iOS 18.
    func testASmallDeviceWithoutAppleSpeechGetsTheUnavailableCandidate() async {
        let models = PinnedModels(root: root, defaults: UserDefaults(suiteName: suite)!, storage: FileSystemStorageProbe())
        XCTAssertEqual(isApple(AppEnvironment.speechTranscriber(models: models, physicalMemory: 4 << 30, platform: .iOS26)),
                       LivePlatform.facts.appleSpeech, "Apple's adapter wherever the system has Apple speech")
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

    /// Without continued processing, work with progress takes the finite time and the runner never registers or
    /// submits a `BGTaskScheduler` request (which would throw below iOS 26); neither does work without progress on
    /// the iOS 26 facts. The iOS 26 request itself is left to the UI tests: a handler is registered once a process.
    func testTheBackgroundRunnerTakesTheFiniteTimeWithoutContinuedProcessing() {
        for (platform, units) in [(PlatformFacts.iOS18, Int64(100)), (.iOS18, 0), (.iOS26, 0)] {
            let runner = UIKitBackgroundRunner(platform: platform)
            let token = runner.begin(title: "Transcribing", subtitle: "Cassini", progress: Progress(totalUnitCount: units)) {}
            XCTAssertEqual(runner.hold(of: token), .finite, "\(platform), \(units) units")
            runner.update(token, title: "Next")
            runner.end(token)
            XCTAssertNil(runner.hold(of: token))
            XCTAssertEqual(runner.registered, [], "\(platform), \(units) units")
        }
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

    private func isApple(_ transcriber: any Transcribing) -> Bool {
        if #available(iOS 26.0, *) { return transcriber is AppleSpeechTranscriber }
        return false
    }
}
