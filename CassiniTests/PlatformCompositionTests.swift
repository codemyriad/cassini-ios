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
        XCTAssertEqual(LivePlatform.whistleOperatingSystemSupported,
                       ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= WhistleCapability.minimumOperatingSystemMajor)
    }

    /// The CPU features come from the system's `sysctl` keys. The simulator answers with the host Mac's, and every
    /// Apple silicon Mac has the atomics and RCpc Whistle needs, so the hosted and UI tests keep Whistle.
    func testTheCPUFeaturesAreTheSystems() throws {
        let lse = try XCTUnwrap(LivePlatform.sysctlBytes(WhistleCPUFeatures.atomicsKey), "the key exists here")
        XCTAssertEqual(lse.count, 4)
        XCTAssertNil(LivePlatform.sysctlBytes("hw.optional.arm.FEAT_CASSINI_NONE"), "an unknown key is no answer")
        XCTAssertEqual(LivePlatform.cpuFeatures, WhistleCPUFeatures(reading: LivePlatform.sysctlBytes))
        #if targetEnvironment(simulator) && arch(arm64)
        XCTAssertTrue(LivePlatform.cpuFeatures.atomics && LivePlatform.cpuFeatures.rcpc)
        XCTAssertTrue(WhistleCapability.supports(cpu: LivePlatform.cpuFeatures, operatingSystemMajor: 18),
                      "the read features alone give Whistle, as on iOS 18")
        #endif
        XCTAssertEqual(LivePlatform.whistleCPUSupported,
                       WhistleCapability.supports(cpu: LivePlatform.cpuFeatures, operatingSystemMajor: LivePlatform.operatingSystemMajor))
    }

    /// The device classes iOS 18 adds, over the facts the live app reads: the A10 iPad (7th generation, 3 GB) has no
    /// recognizer, so Transcribe is disabled with the existing caption; an A12 iPhone XR (3 GB) gets Whistle; and a
    /// device that can hold Parakeet but whose CPU refuses Whistle goes to Parakeet, so a Transcribe asks for its
    /// download. On iOS 26 the CPU read is not consulted (every iOS 26 device is an A12 or newer), so Whistle stays.
    func testIOS18DeviceClassesGetTheirRecognizer() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let a10 = WhistleCPUFeatures(reading: { [WhistleCPUFeatures.atomicsKey: [0, 0, 0, 0]][$0] })
        let a12 = WhistleCPUFeatures(reading: { [WhistleCPUFeatures.atomicsKey: [1, 0, 0, 0], WhistleCPUFeatures.rcpcKey: [1, 0, 0, 0],
                                                 WhistleCPUFeatures.dotProductKey: [0, 0, 0, 0]][$0] })
        func recognizer(_ cpu: WhistleCPUFeatures, memory: UInt64, platform: PlatformFacts, major: Int = 18) -> SpeechRecognizer {
            let whistle = WhistleCapability.bundled(arm64: true, osSupported: WhistleCapability.supports(operatingSystemMajor: major),
                cpuSupported: WhistleCapability.supports(cpu: cpu, operatingSystemMajor: major), bundleVerified: true, physicalMemory: memory)
            return SpeechModelsStore(root: root, defaults: defaults, storage: FakeStorage(), whistle: whistle,
                parakeetLinked: true, platform: platform, physicalMemory: memory,
                availableMemory: { ParakeetMemory.beforeLoadBytes }, installed: { false }, verified: { false }, verify: { false })
                .selectedRecognizer()
        }
        XCTAssertEqual(recognizer(a12, memory: 3 << 30, platform: .iOS18), .whistle)
        XCTAssertEqual(recognizer(a12, memory: 3 << 30, platform: .iOS26, major: 26), .whistle, "unchanged on iOS 26")
        XCTAssertEqual(recognizer(a12, memory: 3 << 30, platform: .iOS18, major: 17), .appleSpeech, "below the floor nothing runs")
        XCTAssertEqual(recognizer(a10, memory: 6 << 30, platform: .iOS18), .parakeet, "Transcribe asks for the Parakeet download")
        let unanswered = WhistleCPUFeatures(reading: { _ in nil })
        XCTAssertEqual(recognizer(unanswered, memory: 3 << 30, platform: .iOS26, major: 26), .whistle,
                       "iOS 26 keeps Whistle even if the system answers no CPU key")
        XCTAssertEqual(recognizer(unanswered, memory: 3 << 30, platform: .iOS18), .appleSpeech, "no answer on iOS 18 refuses")

        // The A10 iPad: no recognizer, so the Apple identity reaches the candidate that refuses before a job is queued.
        XCTAssertEqual(recognizer(a10, memory: 3 << 30, platform: .iOS18), .appleSpeech)
        let models = PinnedModels(root: root, defaults: defaults, storage: FileSystemStorageProbe())
        let refusing = AppEnvironment.speechTranscriber(models: models, physicalMemory: 3 << 30, platform: .iOS18)
        XCTAssertTrue(refusing is UnavailableSpeechTranscriber)
        let failure = await refusing.unavailability(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(failure, .model)
        XCTAssertEqual(failure?.transcriptionMessage,
                       "On-device transcription is unavailable on this device. Your audio can still be played or exported.")
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

    /// Settings follows the facts it is given: it offers Apple's speech language and reports Apple speech as managed by
    /// iOS exactly where the facts say the system has Apple speech, on any system. The adapter alone also needs iOS 26
    /// (a link constraint, not a rule): below it even the iOS 26 facts get the unavailable candidate. The app passes
    /// `LivePlatform.facts`, so the two never disagree outside tests.
    func testSettingsFollowsThePlatform() async {
        for platform in [PlatformFacts.iOS26, .iOS18] {
            let candidate = AppEnvironment.appleSpeechCandidate(platform: platform)
            XCTAssertEqual(isApple(candidate), platform.appleSpeech && LivePlatform.facts.appleSpeech, "\(platform)")
            let test = TestGraph(transcriber: candidate, platform: platform)
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
