import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor private final class ConsentSwitch {
    var allowed = true
}

/// A transcription coordinator over real `NoteStore` and `JobStore` files in a temporary root, with a fake job
/// runner whose runs the test ends, fake saved progress, notifications and background time.
@MainActor final class QueueHarness {
    let root: URL
    let suite: String
    let clock: FakeClock
    let notes: NoteStore
    let jobs: JobStore
    let runner = FakeJobRunner()
    let checkpoints: FakeCheckpoints
    let notifier = FakeNotifier()
    let background = FakeBackgroundRunner()
    let settings: SettingsStore
    let coordinator: TranscriptionCoordinator
    private let consent: ConsentSwitch

    /// Whether the models may be downloaded.
    var consented: Bool {
        get { consent.allowed }
        set { consent.allowed = newValue }
    }

    init(root: URL? = nil, suite: String? = nil, clock: FakeClock = FakeClock(), checkpoints: FakeCheckpoints = FakeCheckpoints()) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.suite = suite ?? "cassini.queue-tests.\(UUID().uuidString)"
        self.clock = clock
        self.checkpoints = checkpoints
        notes = try NoteStore(root: self.root)
        jobs = JobStore(repository: JobRepository(root: self.root))
        settings = SettingsStore(defaults: UserDefaults(suiteName: self.suite)!, clock: clock, defaultLanguage: "it-IT")
        let consent = ConsentSwitch()
        self.consent = consent
        let parts = TranscriptionCoordinator.Parts(
            jobs: jobs, notes: notes, runner: runner, checkpoints: checkpoints,
            consent: ModelConsent { _, _ in consent.allowed }, notifier: notifier, background: background, clock: clock)
        coordinator = TranscriptionCoordinator(parts, settings: settings)
    }

    /// The launch work: the notes, then the queue repair.
    @discardableResult func start(visible: Bool = true) async throws -> ReconcileReport {
        try await notes.load()
        coordinator.setVisible(visible)
        return try await coordinator.reconcileOnStart()
    }

    /// A second launch over the same files, preferences and saved progress.
    func reopened() throws -> QueueHarness {
        try QueueHarness(root: root, suite: suite, clock: clock, checkpoints: checkpoints)
    }

    /// A launch over a copy of `harness`'s files and preferences as they are now, as after a kill at this point:
    /// whatever `harness` writes later never reaches it. Saved progress is shared.
    static func snapshot(of harness: QueueHarness) throws -> QueueHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: harness.root, to: root)
        let suite = "cassini.queue-tests.\(UUID().uuidString)"
        let source = UserDefaults(suiteName: harness.suite)!.persistentDomain(forName: harness.suite) ?? [:]
        UserDefaults(suiteName: suite)!.setPersistentDomain(source, forName: suite)
        return try QueueHarness(root: root, suite: suite, clock: harness.clock, checkpoints: harness.checkpoints)
    }

    /// A plain note, as a finished recording leaves it.
    func note(_ title: String) async throws -> UUID {
        var note = Note(title: title, createdAt: clock.now, audioFilename: "audio.m4a")
        note.duration = 4
        try await notes.save(note)
        return note.id
    }

    func job(_ id: UUID) async -> Job? { await jobs.job(id) }

    /// The `index`th run, once the coordinator started it.
    func run(_ index: Int) async throws -> FakeJobRun { try await runner.run(index) }

    func waitUntil(_ what: Comment = "the condition holds", timeout: Duration = .seconds(10),
                   _ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                throw FakeTimeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets queued work that should not happen show itself.
    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
