import SwiftUI
import CassiniEngine
import CassiniInference
#if DEBUG
import CassiniEngineTesting
#endif

/// Everything the app is built from: where it stores files, its preferences, its clock and locale, and the adapters
/// to the device. `CassiniApp` resolves one at launch; the stores never read the process arguments.
@MainActor struct AppEnvironment {
    var root: URL
    var defaults: UserDefaults
    var clock: any AppClock
    var locale: Locale
    var timeZone: TimeZone
    var transcriber: any Transcribing
    var analyzer: any SpeakerAnalyzing
    var capture: any AudioCapture
    var microphone: any MicrophonePermission
    var liveActivity: (any LiveActivityPort)?
    var playback: any AudioPlayback
    var audio: any AudioProcessing
    var storage: any StorageProbe
    var background: any BackgroundRunner
    /// Result notifications, posted while Cassini is hidden.
    var notifier: any Notifier
    var launch = LaunchOptions()
    /// Where exports wait for the share sheet; the launch sweep empties it.
    var exports = URL.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)

    /// What a UI-test launch asks for.
    struct LaunchOptions {
        var seed: Seed?
        /// A note to open once the library is ready.
        var openFixture: OpenFixture?
        /// Restores the navigation stack saved with the scene.
        var restoresNavigation = true
        /// Shows the UI tests when the launch work is done (`launchFinished`).
        var marksLaunchFinished = false
        /// What the `launchFinished` marker carries: the token of the UI-test relaunch that built this environment.
        var token = ""
    }

    enum OpenFixture: Equatable {
        case newest
        case note(UUID)
    }

    /// Named sets of notes for UI tests and screenshots. `statuses` has a note for each Library row status but
    /// Recording (the recording seed shows that one); `reading` is `search` with word times in the fixture's
    /// passages, so playback highlights one word.
    enum Seed: String, CaseIterable {
        case library, search, speakers, trash, voices, processing, recording, statuses, long, reading
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    static func live() -> AppEnvironment {
        AppEnvironment(
            root: URL.applicationSupportDirectory.appendingPathComponent("Cassini", isDirectory: true),
            defaults: .standard, clock: SystemClock(), locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent,
            transcriber: AppleSpeechTranscriber(), analyzer: SpeakerAnalyzer(storage: FileSystemStorageProbe()), capture: AVCaptureAdapter(),
            microphone: AVMicrophonePermission(), liveActivity: ActivityKitAdapter(), playback: AVPlaybackAdapter(), audio: LocalAudioProcessing(), storage: FileSystemStorageProbe(),
            background: UIKitBackgroundRunner(), notifier: UNNotifier())
    }

    /// The environment the process arguments ask for.
    static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        #if DEBUG
        if arguments.contains("--ui-testing") { return uiTesting(arguments: arguments) }
        #endif
        return live()
    }
}

#if DEBUG
extension AppEnvironment {
    /// Thursday 8 October 2026, 09:41 UTC: every UI-test launch sees the same "today".
    static let uiTestingNow = Date(timeIntervalSince1970: 1_791_452_460)

    /// One runner for every graph of the process: BGTaskScheduler takes a task identifier's handler once a process,
    /// and a relaunch inside the app builds a second graph.
    private static let uiTestingBackground = UIKitBackgroundRunner()

    /// The environment of UI-test launch arguments. A relaunch inside the running app (`UITestRelaunch`) passes
    /// `inProcess` and its `token`.
    static func uiTesting(arguments: [String], inProcess: Bool = false, token: String = "") -> AppEnvironment {
        uiTesting(reset: arguments.contains("--reset-test-data"), seed: seed(in: arguments),
                  openFixture: fixture(in: arguments), modelsMissing: arguments.contains("--models-missing"),
                  modelDownloading: arguments.contains("--model-downloading"),
                  draftGrowing: arguments.contains("--draft-growing"),
                  notificationsDenied: arguments.contains("--notifications-denied"),
                  heldCapture: arguments.contains("--capture-held"), region: value(after: "-AppleLocale", in: arguments),
                  inProcess: inProcess, token: token)
    }

    /// A separate library and preferences, a fixed clock and en_US formatting (or the region of `-AppleLocale`, for the
    /// Italian screenshots). Transcription is faked; the recording seed also fakes the microphone and its permission. With `modelsMissing` the speech and speaker models
    /// are not installed, so a Transcribe asks for the download first; with `modelDownloading` (`--model-downloading`)
    /// the processing seed's job stays in its speech model download at 46 %, and with `draftGrowing` (`--draft-growing`)
    /// its draft grows by a sentence every half second. `heldCapture` (`--capture-held`) starts the recording seed's
    /// capture 24 minutes in and holds it after 7 s of speech-like levels, with 64 GiB free, for the screenshots. A second transcription of the same note hears other words
    /// (`TestFixtures.transcribedAgainSegments`). Speaker models are installed on the recording seed only.
    /// Notifications are never asked for and count as allowed, so no banner says they are off, unless
    /// `notificationsDenied` (`--notifications-denied`) turns them off.
    static func uiTesting(reset: Bool, seed: Seed?, openFixture: OpenFixture? = nil,
                          modelsMissing: Bool = false, modelDownloading: Bool = false, draftGrowing: Bool = false,
                          notificationsDenied: Bool = false, heldCapture: Bool = false, region: String? = nil,
                          inProcess: Bool = false, token: String = "") -> AppEnvironment {
        let storage = UITestStorage.generation(reset: reset, inProcess: inProcess)
        let root = storage.root
        let defaults = UserDefaults(suiteName: storage.suite) ?? .standard
        let status: ModelPartStatus = modelsMissing ? .notDownloaded : .ready
        let transcriber = switch seed {
        case .processing where modelDownloading: FakeTranscriber(.downloading(fraction: 0.46), status: status)
        case .processing where draftGrowing:
            FakeTranscriber(.growing(TestFixtures.growingDraft, every: .milliseconds(500), total: TestFixtures.processingDuration),
                            status: status)
        case .processing:
            FakeTranscriber(.frozen(done: 0.62 * TestFixtures.processingDuration, total: TestFixtures.processingDuration,
                                    draft: TestFixtures.processingDraft), status: status)
        case .statuses:
            FakeTranscriber(.frozen(done: 0.62 * TestFixtures.processingDuration, total: TestFixtures.processingDuration),
                            status: status)
        default:
            FakeTranscriber(.sequence([TestFixtures.transcribedSegments, TestFixtures.transcribedAgainSegments],
                                      total: TestFixtures.fixtureDuration), status: status)
        }
        // The recording seed tells the speakers apart, as a walk from recording to naming needs.
        let analyzer = seed == .recording ? FakeAnalyzer(analysis: TestFixtures.recordingAnalysis)
            : FakeAnalyzer(modelIdentity: nil)
        return AppEnvironment(
            root: root, defaults: defaults, clock: FixedClock(now: uiTestingNow),
            locale: Locale(identifier: region ?? "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            transcriber: transcriber, analyzer: analyzer,
            capture: seed != .recording ? AVCaptureAdapter()
                : heldCapture ? FakeCapture(levels: TestFixtures.speechLevels, heldAt: TestFixtures.heldCaptureStart) : FakeCapture(),
            microphone: seed == .recording ? FakeMicrophonePermission() : AVMicrophonePermission(),
            liveActivity: ActivityKitAdapter(), playback: AVPlaybackAdapter(), audio: LocalAudioProcessing(),
            // A held capture also holds the free space, so its hint reads the same on every run.
            storage: heldCapture ? FakeStorage() : FileSystemStorageProbe(),
            background: uiTestingBackground, notifier: FakeNotifier(auth: notificationsDenied ? .denied : .authorized),
            launch: LaunchOptions(seed: seed, openFixture: openFixture, restoresNavigation: false, marksLaunchFinished: true,
                                  token: token))
    }

    /// `--seed <name>`; `--seed-test-data` is the library seed.
    private static func seed(in arguments: [String]) -> Seed? {
        if let name = value(after: "--seed", in: arguments) { return Seed(rawValue: name) }
        return arguments.contains("--seed-test-data") ? .library : nil
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `--open-fixture [note id]`: the given note, or the newest.
    private static func fixture(in arguments: [String]) -> OpenFixture? {
        guard let index = arguments.firstIndex(of: "--open-fixture") else { return nil }
        let id = arguments.indices.contains(index + 1) ? UUID(uuidString: arguments[index + 1]) : nil
        return id.map(OpenFixture.note) ?? .newest
    }
}
#endif

extension EnvironmentValues {
    /// The clock dates are shown against.
    @Entry var clock: any AppClock = SystemClock()
    /// Screens restore what they saved with the scene, such as the library search.
    @Entry var restoresSceneState = true
}
