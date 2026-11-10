import Foundation
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// An app graph on a temporary root with its own preferences suite and fakes for the device, so a test never touches
/// the real library or `UserDefaults.standard`.
@MainActor final class TestGraph {
    let root: URL
    let suite: String
    let clock: FakeClock
    let background = FakeBackgroundRunner()
    let notifier = FakeNotifier(auth: .notDetermined)
    let playback = FakePlayback(fileDuration: 2)
    let capture = FakeCapture()
    let microphone = FakeMicrophonePermission()
    let liveActivity = FakeLiveActivity()
    let graph: AppGraph

    init(root: URL? = nil, suite: String? = nil, clock: FakeClock = FakeClock(),
         transcriber: any Transcribing = FakeTranscriber(.returns([], total: 1)), analyzer: any SpeakerAnalyzing = FakeAnalyzer(), speechModels: SpeechModelsStore? = nil,
         downloadTranscriber: (any Transcribing)? = nil, modelRoot: URL? = nil, platform: PlatformFacts = .iOS26,
         audio: any AudioProcessing = LocalAudioProcessing()) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.suite = suite ?? "cassini.tests.\(UUID().uuidString)"
        self.clock = clock
        var environment = AppEnvironment(
            root: self.root, defaults: UserDefaults(suiteName: self.suite)!, clock: clock,
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!,
            transcriber: transcriber, analyzer: analyzer, capture: capture, microphone: microphone,
            liveActivity: liveActivity, playback: playback,
            audio: audio, storage: FakeStorage(), background: background, notifier: notifier,
            platform: platform)
        environment.recordingClock = RecordingClock(now: clock)
        environment.exports = self.root.appendingPathComponent("tmp/Exports", isDirectory: true)
        environment.speechModels = speechModels
        environment.downloadTranscriber = downloadTranscriber
        if let modelRoot { environment.models = modelRoot }
        graph = AppGraph(environment: environment)
    }

    /// A second launch over the same files and preferences.
    func reopened() -> TestGraph { TestGraph(root: root, suite: suite, clock: clock) }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

/// Hosted smoke checks keep their existing real timer cadence; FakeClock still removes search debounce.
/// Forward dates to the graph's clock so recordings and the library always agree about "now".
private struct RecordingClock: AppClock {
    let source: FakeClock
    init(now source: FakeClock) { self.source = source }
    var now: Date { source.now }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
