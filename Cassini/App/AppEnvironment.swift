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
    /// Result notifications; `SilentNotifier` stands in until the notification adapter lands.
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
    }

    enum OpenFixture: Equatable {
        case newest
        case note(UUID)
    }

    /// Named sets of notes for UI tests and screenshots.
    enum Seed: String, CaseIterable {
        case library, search, speakers, trash, voices, processing, recording
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
            background: UIKitBackgroundRunner(), notifier: SilentNotifier())
    }

    /// The environment the process arguments ask for.
    static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        #if DEBUG
        if arguments.contains("--ui-testing") {
            return uiTesting(reset: arguments.contains("--reset-test-data"), seed: seed(in: arguments),
                             openFixture: fixture(in: arguments), modelsMissing: arguments.contains("--models-missing"))
        }
        #endif
        return live()
    }
}

#if DEBUG
extension AppEnvironment {
    static let uiTestingSuite = "app.codemyriad.cassini.ui-tests"
    /// Thursday 8 October 2026, 09:41 UTC: every UI-test launch sees the same "today".
    static let uiTestingNow = Date(timeIntervalSince1970: 1_791_452_460)

    /// A separate library and preferences, a fixed clock and en_US formatting. Transcription is faked; the
    /// recording seed also fakes the microphone and its permission. With `modelsMissing` the speech and speaker models
    /// are not installed, so a Transcribe asks for the download first. Speaker models are never installed.
    /// Notifications are never asked for.
    static func uiTesting(reset: Bool, seed: Seed?, openFixture: OpenFixture? = nil,
                          modelsMissing: Bool = false) -> AppEnvironment {
        let root = URL.applicationSupportDirectory.appendingPathComponent("CassiniUITests", isDirectory: true)
        let defaults = UserDefaults(suiteName: uiTestingSuite) ?? .standard
        if reset {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: uiTestingSuite)
        }
        let status: ModelPartStatus = modelsMissing ? .notDownloaded : .ready
        let transcriber = seed == .processing
            ? FakeTranscriber(.frozen(done: 0.62 * TestFixtures.processingDuration, total: TestFixtures.processingDuration),
                              status: status)
            : FakeTranscriber(.returns(TestFixtures.transcribedSegments, total: TestFixtures.fixtureDuration), status: status)
        return AppEnvironment(
            root: root, defaults: defaults, clock: FixedClock(now: uiTestingNow),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            transcriber: transcriber, analyzer: FakeAnalyzer(modelIdentity: nil),
            capture: seed == .recording ? FakeCapture() : AVCaptureAdapter(),
            microphone: seed == .recording ? FakeMicrophonePermission() : AVMicrophonePermission(),
            liveActivity: ActivityKitAdapter(), playback: AVPlaybackAdapter(), audio: LocalAudioProcessing(), storage: FileSystemStorageProbe(),
            background: UIKitBackgroundRunner(), notifier: FakeNotifier(auth: .denied),
            launch: LaunchOptions(seed: seed, openFixture: openFixture, restoresNavigation: false))
    }

    /// `--seed <name>`; `--seed-test-data` is the library seed.
    private static func seed(in arguments: [String]) -> Seed? {
        if let index = arguments.firstIndex(of: "--seed"), arguments.indices.contains(index + 1) {
            return Seed(rawValue: arguments[index + 1])
        }
        return arguments.contains("--seed-test-data") ? .library : nil
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
