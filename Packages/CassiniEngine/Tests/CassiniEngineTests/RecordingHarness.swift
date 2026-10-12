import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// A recording controller over a real `NoteStore` on a temporary root, with a scripted microphone, fake storage, fake
/// compression and a fake hand-off. The policy loop ticks every 10 ms.
@MainActor final class RecordingHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "cassini.recording.tests.\(UUID().uuidString)"
    let capture = ScriptedCapture()
    let storage = FakeStorage()
    let audio = FakeAudioProcessing(duration: 2, opensAnyFile: true)
    let handoff = FakeRecordingHandoff()
    let activity = FakeLiveActivity()
    let notifier = FakeNotifier()
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_791_452_460))
    let settings: SettingsStore
    let store: NoteStore
    let notes: CountingRecordingNotes
    let controller: RecordingController
    var isReady = true

    static let debounce: Duration = .milliseconds(50)

    init(consented: Bool = true) throws {
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, defaultLanguage: "en-US")
        if consented { settings.recordConsent() }
        store = try NoteStore(root: root)
        notes = CountingRecordingNotes(store: store)
        var harness: RecordingHarness?
        controller = RecordingController(parts: .init(
            ready: { while harness?.isReady == false { try? await Task.sleep(for: .milliseconds(5)) } },
            notes: notes, capture: capture, storage: storage, audio: audio, settings: settings, handoff: handoff,
            liveActivity: activity, notifier: notifier, clock: clock,
            defaultTitle: { "Voice note \(RecordingTitles.dateTime($0, locale: Locale(identifier: "en_US"), timeZone: .gmt))" },
            timing: .init(tick: .milliseconds(10), titleDebounce: Self.debounce)))
        harness = self
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    var active: ActiveRecording {
        get throws { try #require(controller.state.activeRecording, "Not recording: \(controller.state)") }
    }

    @discardableResult
    func startRecording() async throws -> ActiveRecording {
        #expect(controller.start())
        try await waitFor { self.controller.state.isActive || self.isEnded }
        return try active
    }

    var isEnded: Bool { if case .ended = controller.state { true } else { false } }

    func awaitEnded() async throws -> RecordingState {
        try await waitFor { self.isEnded }
        return controller.state
    }

    func note(_ id: UUID) async -> Note? { await store.note(id) }

    func waitFor(_ what: String = "condition", timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
