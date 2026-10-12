import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniNotebook

/// The Library's model over plain ports (Android `LibraryViewModelTest`).
@MainActor @Suite struct LibraryScreenModelTests {
    /// A clock whose sleeps wait until `release()`, so a test sees the state before and after the debounce.
    final class GatedClock: AppClock {
        let now = Date(timeIntervalSince1970: 1_791_452_460)
        private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
        var sleeping: Int { waiters.withLock { $0.count } }

        func sleep(for duration: Duration) async throws {
            await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
            try Task.checkCancellation()
        }

        func release() {
            let waiting = waiters.withLock { waiting in defer { waiting = [] }; return waiting }
            waiting.forEach { $0.resume() }
        }
    }

    @MainActor final class Library {
        var notes: [Note] = []
        var loading = false
        var unavailable = false
        var processing = ProcessingState()
        var recording = RecordingState.idle
        var outcome = TranscribeOutcome.queued(changed: true)
        var actions: [String] = []
        var effects: [LibraryEffect] = []
        let clock = GatedClock()
        lazy var model: LibraryScreenModel = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let model = LibraryScreenModel(ports: .init(
                notes: { [unowned self] in notes }, loading: { [unowned self] in loading },
                unavailable: { [unowned self] in unavailable }, processing: { [unowned self] in processing },
                phase: { _ in nil }, install: { nil }, recording: { [unowned self] in recording },
                transcribe: { [unowned self] id, kind in
                    actions.append("transcribe \(title(id)) \(kind)")
                    return outcome
                },
                clock: clock, calendar: calendar))
            model.onEffect = { [unowned self] in effects.append($0) }
            return model
        }()

        @discardableResult
        func add(_ title: String, _ text: String = "", minutesAgo: Double = 0) -> UUID {
            var note = Note(title: title, createdAt: clock.now.addingTimeInterval(-minutesAgo * 60))
            if !text.isEmpty { note.transcript = [TranscriptSegment(text: text, start: 0, end: 1)] }
            notes.append(note)
            notes.sort { $0.createdAt > $1.createdAt }
            return note.id
        }

        func title(_ id: UUID) -> String { notes.first { $0.id == id }?.title ?? "?" }
    }

    // ports: LibraryViewModelTest#searchesAfterTheDebounceAndKeepsTheQuery
    @Test func searchesAfterTheDebounceAndKeepsTheQuery() async {
        let library = Library()
        library.add("a", minutesAgo: 1)
        let hit = library.add("Fattura")
        let model = library.model
        model.query = "fatt"
        #expect(model.query == "fatt")
        #expect(model.searched == "", "nothing searched before the debounce")
        #expect(model.content.results == [], "the results are empty until the search answers")
        #expect(model.content.emptyState == nil)
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settleSearch()
        #expect(model.searched == "fatt")
        let results = model.content.results ?? []
        #expect(results.map(\.id) == [hit])
        #expect(results.first?.titleRanges == [0..<7])
        #expect(model.content.sections.isEmpty)

        model.query = "zzz"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settleSearch()
        #expect(model.content.emptyState == .noMatch("zzz"))

        model.query = ""
        #expect(model.searched == "", "an empty query applies at once")
        #expect(model.content.results == nil)
        #expect(model.content.sections.first?.rows.count == 2)
    }

    @Test func aNewKeystrokeRestartsTheDebounce() async {
        let library = Library()
        library.add("Fattura")
        let model = library.model
        model.query = "fa"
        await waitUntilSleeping(library.clock, count: 1)
        model.query = "fat"
        await waitUntilSleeping(library.clock, count: 2)
        library.clock.release()
        await model.settleSearch()
        #expect(model.searched == "fat")
        model.query = " fat "
        #expect(model.searched == "fat", "the trimmed query did not change: nothing to search again")

        model.query = "fatt"
        await waitUntilSleeping(library.clock, count: 1)
        model.query = ""
        library.clock.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.searched == "", "clearing the field cancels the search waiting for its debounce")
    }

    // ports: LibraryViewModelTest#opensNotesWithTheQueryAndRecording
    @Test func opensNotesWithTheQueryAndRecording() async {
        let library = Library()
        let a = library.add("a"), b = library.add("b")
        var recorded = Note(title: "Standup")
        recorded.audio = .live
        library.notes.append(recorded)
        library.recording = .active(ActiveRecording(noteID: recorded.id, title: "Standup", defaultTitle: "", format: .pcm48kMono))
        let model = library.model
        model.open(a)
        model.query = " giov "
        model.open(b)
        model.open(recorded.id)
        #expect(library.effects == [.openNote(.note(a)), .openNote(.note(b, query: "giov")), .openRecording])
    }

    // ports: LibraryViewModelTest#resumeWithoutConsentOpensModelDownload
    @Test func resumeWithoutConsentOpensModelDownload() async {
        let library = Library()
        let paused = library.add("p")
        library.processing.jobs[paused] = Job(noteID: paused, seq: 1, kind: .transcribeAgain, state: .paused, doneMs: 5,
                                              enqueuedAt: library.clock.now)
        library.outcome = .needsConsent
        await library.model.resume(paused)
        #expect(library.effects == [.openModelDownload(noteID: paused)])
        #expect(library.actions == ["transcribe p transcribeAgain"])
    }

    @Test func tryAgainAfterAFinalFailureOpensTheNote() async {
        let library = Library()
        let long = library.add("long")
        library.processing.jobs[long] = Job(noteID: long, seq: 1, kind: .transcribe, state: .failed, failure: .long,
                                            enqueuedAt: library.clock.now)
        await library.model.resume(long)
        #expect(library.effects == [.openNote(.note(long))])
        #expect(library.actions.isEmpty)

        let failed = library.add("failed")
        library.processing.jobs[failed] = Job(noteID: failed, seq: 2, kind: .transcribe, state: .failed, failure: .audio,
                                              enqueuedAt: library.clock.now)
        library.outcome = .refused(.unplayable)
        await library.model.resume(failed)
        #expect(library.actions == ["transcribe failed transcribe"])
        #expect(library.effects.last == .refused(.unplayable))
    }

    // ports: LibraryViewModelTest#aCatalogueThatCannotBeReadIsNotAnEmptyLibrary
    @Test func aCatalogueThatCannotBeReadIsNotAnEmptyLibrary() {
        let library = Library()
        library.unavailable = true
        #expect(library.model.content.emptyState == .unavailable)
        #expect(library.model.content.sections.isEmpty)
    }

    @Test func anEmptyLibraryWaitsUntilItIsRead() {
        let library = Library()
        library.loading = true
        #expect(library.model.content.emptyState == nil, "never flashes before the notes are read")
        library.loading = false
        #expect(library.model.content.emptyState == .empty)
    }

    // ports: LibraryViewModelTest#theProgressBannerOpensTheRunningNoteOrSettings
    @Test func theProgressBannerOpensTheRunningNoteOrSettings() {
        let library = Library()
        library.model.openProgress()
        let running = library.add("Weekly")
        library.processing.running = RunningJob(noteID: running, title: "Weekly")
        library.model.openProgress()
        #expect(library.effects == [.openSettings, .openNote(.note(running))])
        #expect(library.model.progress?.noteID == running)
    }

    /// The Starred filter, an iOS extra.
    @Test func theStarredFilterKeepsOnlyStarredNotes() {
        let library = Library()
        library.add("plain")
        let starred = library.add("starred")
        library.notes[library.notes.firstIndex { $0.id == starred }!].isFavorite = true
        library.model.favoritesOnly = true
        #expect(library.model.content.sections.flatMap(\.rows).map(\.id) == [starred])
        library.notes.removeAll { $0.id == starred }
        #expect(library.model.content.emptyState == .noStarred)
    }

    private func waitUntilSleeping(_ clock: GatedClock, count: Int = 1) async {
        while clock.sleeping < count { await Task.yield() }
    }
}
