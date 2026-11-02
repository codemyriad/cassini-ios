import SwiftUI
import CassiniEngine
import CassiniInference
import CassiniSherpa
import CassiniNotebook
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
    /// Where the pinned models (Parakeet Ultra, Silero VAD) are installed, excluded from backups.
    var models = ModelCatalog.defaultRoot

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

    /// Parakeet Ultra when this build links the native runtime and the device can hold it (`SpeechCapability`),
    /// whether or not its model is installed: a job downloads Ultra and its speech detector through the shared
    /// installer with consent, and the model download screen's Download does too. Apple Speech otherwise (decision D2).
    /// Chosen once at launch.
    static func speechTranscriber(models: PinnedModels,
                                  physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> any Transcribing {
        switch SpeechCapability.choose(linked: SherpaRuntime.isLinked,
                                       capable: SpeechCapability.parakeetCapable(physicalMemory: physicalMemory)) {
        case .parakeet:
            ParakeetTranscriber(models: .init(installer: models.installer, root: models.root,
                                              online: { NetworkPath.shared.isOnline }),
                                runtime: SherpaRuntime.speech)
        case .appleSpeech: AppleSpeechTranscriber()
        }
    }

    /// Android's speaker pipeline (streaming Sortformer and CAM++) over the catalog's pinned files, which the shared
    /// installer fetches. Without the native runtime the speaker models are unsupported.
    static func speakerAnalyzer(models: PinnedModels) -> SpeakerAnalyzer {
        SpeakerAnalyzer(models: SpeakerModels(repository: models.repository, installer: models.installer),
                        runtime: SherpaRuntime.speakers)
    }

    static func live() -> AppEnvironment {
        let storage = FileSystemStorageProbe()
        let models = PinnedModels(root: ModelCatalog.defaultRoot, defaults: .standard, storage: storage)
        return AppEnvironment(
            root: URL.applicationSupportDirectory.appendingPathComponent("Cassini", isDirectory: true),
            defaults: .standard, clock: SystemClock(), locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent,
            transcriber: speechTranscriber(models: models), analyzer: speakerAnalyzer(models: models),
            capture: AVCaptureAdapter(), microphone: AVMicrophonePermission(), liveActivity: ActivityKitAdapter(),
            playback: AVPlaybackAdapter(), audio: LocalAudioProcessing(), storage: storage,
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
                  speakersReady: arguments.contains("--speakers-ready"),
                  parakeet: arguments.contains("--parakeet"),
                  notificationsDenied: arguments.contains("--notifications-denied"),
                  heldCapture: arguments.contains("--capture-held"), region: value(after: "-AppleLocale", in: arguments),
                  inProcess: inProcess, token: token)
    }

    /// A separate library and preferences, a fixed clock and en_US formatting (or the region of `-AppleLocale`, for the
    /// Italian screenshots). Transcription is faked; the recording seed also fakes the microphone and its permission. With `modelsMissing` the speech and speaker models
    /// are not installed, so a Transcribe asks for the download first; with `modelDownloading` (`--model-downloading`)
    /// the processing seed's job stays in its speech model download at 46 %, and with `draftGrowing` (`--draft-growing`)
    /// its draft grows by a sentence every half second. `heldCapture` (`--capture-held`) starts the recording seed's
    /// capture 24 minutes in and holds it after 7 s of speech-like levels, with 64 GiB free, for the screenshots. Speaker models are installed on the recording and processing seeds
    /// only, or on any seed with `speakersReady` (`--speakers-ready`), whose speaker step finds the fixture's two voices
    /// taking turns; the processing seed's job has measured its pace, so its card shows a time left.
    /// Notifications are never asked for and count as allowed, so no banner says they are off, unless
    /// `notificationsDenied` (`--notifications-denied`) turns them off. With `parakeet` (`--parakeet`) the fake
    /// transcriber stands for Parakeet Ultra, as on a device that can hold it: the model download screen and the
    /// speech row show Ultra's sizes.
    static func uiTesting(reset: Bool, seed: Seed?, openFixture: OpenFixture? = nil,
                          modelsMissing: Bool = false, modelDownloading: Bool = false, draftGrowing: Bool = false,
                          speakersReady: Bool = false, parakeet: Bool = false,
                          notificationsDenied: Bool = false, heldCapture: Bool = false, region: String? = nil,
                          inProcess: Bool = false, token: String = "") -> AppEnvironment {
        let storage = UITestStorage.generation(reset: reset, inProcess: inProcess)
        let root = storage.root
        let defaults = UserDefaults(suiteName: storage.suite) ?? .standard
        let status: ModelPartStatus = modelsMissing ? .notDownloaded : .ready
        let recognizer: SpeechRecognizer = parakeet ? .parakeet : .appleSpeech
        let script: FakeTranscriber.Script = switch seed {
        case .processing where modelDownloading: .downloading(fraction: 0.46)
        case .processing where draftGrowing:
            .growing(TestFixtures.growingDraft, every: .milliseconds(500), total: TestFixtures.processingDuration)
        case .processing:
            .frozen(done: 0.62 * TestFixtures.processingDuration, total: TestFixtures.processingDuration,
                    draft: TestFixtures.processingDraft, pace: TestFixtures.processingPace)
        case .statuses:
            .frozen(done: 0.62 * TestFixtures.processingDuration, total: TestFixtures.processingDuration)
        default:
            .returns(TestFixtures.transcribedSegments, total: TestFixtures.fixtureDuration)
        }
        let transcriber = FakeTranscriber(script, status: status, recognizer: recognizer)
        // The recording seed tells the speakers apart, as a walk from recording to naming needs; the processing seed's
        // job has its speaker step ahead.
        let analyzer = switch seed {
        case .recording, _ where speakersReady && !modelsMissing: FakeAnalyzer(analysis: TestFixtures.recordingAnalysis)
        case .processing where !modelsMissing: FakeAnalyzer()
        default: FakeAnalyzer(modelIdentity: nil)
        }
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
                                  token: token),
            models: root.appendingPathComponent("CassiniModels", isDirectory: true))
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

/// The catalog's models of one app run (Parakeet Ultra, Silero VAD, the diarizer and CAM++ under `root`): one
/// repository and one installer, which speech and the speaker models share, so one install runs at a time and a job
/// that joins the standalone download fetches each file once (Android's single `ModelInstallOwner`). The fetcher
/// resumes with Range and decompresses each file's seekable Zstandard; the repository reads the speech consent from
/// `defaults`. Every request to the model host names the app in `userAgent` (D54).
struct PinnedModels: Sendable {
    let root: URL
    let repository: ModelRepository
    let installer: PinnedModelInstaller

    /// `fetcher` replaces the model host in tests.
    init(root: URL, defaults: UserDefaults, storage: any StorageProbe, userAgent: String = PinnedModels.userAgent,
         fetcher: (any ModelFetching)? = nil) {
        let fetcher = fetcher ?? NetworkModelFetcher(
            fetcher: ArtifactFetcher(transport: URLSessionTransport(userAgent: userAgent), storage: storage),
            decoder: ZstdDecompressor())
        self.root = root
        repository = ModelRepository(root: root, consent: DefaultsModelConsent(defaults: defaults), fetcher: fetcher)
        installer = PinnedModelInstaller(models: repository, storage: storage, online: { NetworkPath.shared.isOnline })
    }
}

extension PinnedModels {
    /// `CassiniTalk/<CFBundleShortVersionString> (iOS <version>; build <CFBundleVersion>)` (D54), read once from the
    /// app's bundle and the system: the version a person sees in Settings, never a literal.
    static let userAgent = ModelUserAgent.string(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        system: ProcessInfo.processInfo.operatingSystemVersion,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
}

/// The speech consent the model repository reads (`models.consentAt`, as `SettingsStore` writes it), before the stores
/// exist. The speaker models have a consent of their own, which the job and the download screen check; their install
/// is granted, so this only feeds the repository's status.
struct DefaultsModelConsent: ModelConsentRecords, @unchecked Sendable {
    let defaults: UserDefaults

    func consentAt() async -> Date? {
        (defaults.object(forKey: SettingsKeys.modelsConsentAt) as? NSNumber)
            .map { Date(timeIntervalSince1970: Double($0.int64Value) / 1000) }
    }

    func recordConsent() async {
        defaults.set(NSNumber(value: Int64((Date().timeIntervalSince1970 * 1000).rounded())), forKey: SettingsKeys.modelsConsentAt)
    }

    func recordDeclined() async {
        defaults.set(NSNumber(value: Int64((Date().timeIntervalSince1970 * 1000).rounded())), forKey: SettingsKeys.modelsDeclinedAt)
    }
}

extension EnvironmentValues {
    /// The clock dates are shown against.
    @Entry var clock: any AppClock = SystemClock()
    /// Screens restore what they saved with the scene, such as the library search.
    @Entry var restoresSceneState = true
    /// Where the pinned models are installed (`AppEnvironment.models`); About reads the model host's notices there.
    @Entry var modelRoot: URL = ModelCatalog.defaultRoot
}
