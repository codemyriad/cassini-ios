import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// A recording controller over a real `NoteStore` on a temporary root, with a scripted microphone, fake storage, fake
/// compression and a fake hand-off. The harness drives policy ticks and title debounce through a manual clock.
@MainActor final class RecordingHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "cassini.recording.tests.\(UUID().uuidString)"
    let capture = ScriptedCapture()
    let storage = FakeStorage()
    let audio = FakeAudioProcessing(duration: 2, opensAnyFile: true)
    let handoff = FakeRecordingHandoff()
    let activity = FakeLiveActivity()
    let notifier = FakeNotifier()
    let clock = RecordingTestClock(now: Date(timeIntervalSince1970: 1_791_452_460))
    let settings: SettingsStore
    let store: NoteStore
    let notes: CountingRecordingNotes
    let controller: RecordingController
    var isReady = true
    /// How often a start has asked whether the app is ready.
    private(set) var readyChecks = 0

    static let debounce: Duration = .milliseconds(50)

    init(consented: Bool = true, consent: ModelConsent? = nil,
         recordingNotes: ((CountingRecordingNotes) -> any RecordingNotes)? = nil) throws {
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, defaultLanguage: "en-US")
        if consented { settings.recordConsent() }
        store = try NoteStore(root: root)
        notes = CountingRecordingNotes(store: store)
        weak var harness: RecordingHarness?
        controller = RecordingController(parts: .init(
            ready: {
                while harness?.isReady == false { harness?.readyChecks += 1; try? await Task.sleep(for: .milliseconds(5)) }
            },
            notes: recordingNotes?(notes) ?? notes, capture: capture, storage: storage, audio: audio, settings: settings, handoff: handoff, consent: consent,
            liveActivity: activity, notifier: notifier, clock: clock,
            defaultTitle: { "Voice note \(RecordingTitles.dateTime($0, locale: Locale(identifier: "en_US"), timeZone: .gmt))" },
            timing: .init(tick: .milliseconds(10), titleDebounce: Self.debounce)))
        harness = self
    }

    func tearDown() {
        controller.policy?.cancel()
        controller.titleWrite?.cancel()
        controller.events?.cancel()
        clock.cancelAll()
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

    /// Returns once the controller has handled every event the capture has sent so far (E1: before a check that
    /// an event changed nothing, rather than a sleep that a busy host lets pass first).
    func eventsHandled() async throws {
        try await waitFor("the capture's events are handled") { controller.handledEvents >= capture.sent }
    }

    /// Await the captured title task to completion, driving its scheduler rather than waiting a quiet interval.
    func settle() async throws {
        var finished = false
        let controller = controller
        let task = Task { await controller.settle(); finished = true }
        defer { task.cancel() }
        try await waitFor("the pending title work") { finished }
        await task.value
    }

    func waitFor(_ what: String = "condition", timeout: Duration = .seconds(30), advancingClock: Bool = true, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            if advancingClock { clock.advanceToNextSleep() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
