import Foundation
import Observation
import Synchronization
import Testing
import CassiniCore
@testable import CassiniEngine
import CassiniNotebook

/// The Library's model over plain ports (Android `LibraryViewModelTest`).
@MainActor @Suite struct LibraryScreenModelTests {
    /// A clock whose sleeps wait until `release()`, so a test sees the state before and after the debounce.
    final class GatedClock: AppClock {
        private let current = Mutex(Date(timeIntervalSince1970: 1_791_452_460))
        var now: Date { current.withLock { $0 } }
        private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
        var sleeping: Int { waiters.withLock { $0.count } }

        func sleep(for duration: Duration) async throws {
            await withCheckedContinuation { continuation in waiters.withLock { $0.append(continuation) } }
            try Task.checkCancellation()
        }

        func set(_ date: Date) { current.withLock { $0 = date } }

        func release() {
            let waiting = waiters.withLock { waiting in defer { waiting = [] }; return waiting }
            waiting.forEach { $0.resume() }
        }
    }

    @MainActor @Observable final class Library {
        var notes: [Note] = []
        var loading = false
        var unavailable = false
        var processing = ProcessingState()
        var recording = RecordingState.idle
        var outcome = TranscribeOutcome.queued(changed: true)
        var actions: [String] = []
        var effects: [LibraryEffect] = []
        var finishing: UUID?
        var speakerModelsReady = false
        var cloudBackup: Bool? = true
        var defaults: UserDefaults?
        @ObservationIgnored let clock = GatedClock()
        @ObservationIgnored lazy var model: LibraryScreenModel = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let model = LibraryScreenModel(ports: .init(
                notes: { [unowned self] in notes }, loading: { [unowned self] in loading },
                unavailable: { [unowned self] in unavailable }, processing: { [unowned self] in processing },
                phase: { _ in nil }, install: { nil }, recording: { [unowned self] in recording },
                finishing: { [unowned self] in finishing },
                transcribe: { [unowned self] id, kind in
                    actions.append("transcribe \(title(id)) \(kind)")
                    return outcome
                },
                startOver: { [unowned self] id in
                    actions.append("startOver \(title(id))")
                    return outcome
                },
                stop: { [unowned self] in actions.append("stop \(title($0))") },
                dequeue: { [unowned self] in actions.append("dequeue \(title($0))") },
                update: { [unowned self] id, change in
                    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
                    change(&notes[index])
                    actions.append("update \(title(id))")
                },
                trash: { [unowned self] in actions.append("trash \(title($0))") },
                speakerModelsReady: { [unowned self] in speakerModelsReady },
                setRecordingTitle: { [unowned self] in actions.append("recordingTitle \($0)") },
                cloudBackup: { [unowned self] in cloudBackup },
                clock: clock, calendar: calendar), defaults: defaults)
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

    @Test func renameUpdatesOnlyTheMatchingActiveRecorderWithTheCleanTitle() async {
        let library = Library()
        let live = library.add("Live"), other = library.add("Other")
        library.recording = .active(ActiveRecording(noteID: live, title: "Live", defaultTitle: "Live", format: .pcm48kMono))
        let model = library.model
        #expect(model.rename(other, to: "Other renamed"))
        #expect(!library.actions.contains(where: { $0.hasPrefix("recordingTitle") }))
        #expect(!model.rename(live, to: "   "))
        #expect(model.rename(live, to: "  Live renamed  "))
        #expect(library.actions.suffix(2) == ["recordingTitle Live renamed", "update Live renamed"])
        await model.settle()
        library.actions = []
        #expect(model.rename(live, to: "Live renamed"))
        #expect(library.actions.isEmpty)
        library.recording = .idle
        #expect(model.rename(live, to: "Saved renamed"))
        #expect(library.actions == ["update Saved renamed"])
    }

    @Test func rememberedStarredAppliesToTheVeryFirstProjection() throws {
        let suite = "D1042-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Library()
        first.defaults = defaults
        #expect(!first.model.favoritesOnly)
        first.model.favoritesOnly = true
        let next = Library()
        next.defaults = defaults
        let unstarred = next.add("Unstarred")
        let starred = next.add("Starred")
        next.notes[next.notes.firstIndex { $0.id == starred }!].isFavorite = true
        let initial = next.model.content
        #expect(initial.sections.flatMap(\.rows).map(\.id) == [starred])
        #expect(!initial.sections.flatMap(\.rows).contains { $0.id == unstarred })
        next.notes = []
        // A fresh model with no meetings still shows the shared starred empty state.
        let empty = Library()
        empty.defaults = defaults
        #expect(empty.model.content.emptyState == .noStarred)
        empty.model.favoritesOnly = false
        let all = Library()
        all.defaults = defaults
        #expect(!all.model.favoritesOnly)
    }

    @Test func unifiedFiltersCombineAndCloseRestoresTheLibraryChoice() async throws {
        let library = Library()
        let own = library.add("Planning own", "Planning")
        let imported = library.add("Planning imported", "Planning")
        let document = library.add("Planning document", "Planning")
        let recovered = library.add("Planning recovered", "Planning")
        let otherSpeaker = library.add("Planning Bob", "Planning")
        let old = library.add("Planning last year", "Planning", minutesAgo: 400 * 24 * 60)
        let unstarred = library.add("Planning unstarred", "Planning")
        let unrelated = library.add("Unrelated")
        for i in library.notes.indices {
            library.notes[i].isFavorite = library.notes[i].id != unstarred
            library.notes[i].transcript = library.notes[i].transcript.map { segment in
                var segment = segment; segment.speakerID = "s1"; return segment
            }
            library.notes[i].speakers = [NoteSpeaker(id: "s1", name: library.notes[i].id == otherSpeaker ? "Bob" : "Alice")]
        }
        library.notes[library.notes.firstIndex { $0.id == imported }!].origin = .imported
        library.notes[library.notes.firstIndex { $0.id == document }!].origin = .importedDocument
        library.notes[library.notes.firstIndex { $0.id == recovered }!].origin = .recovered
        let model = library.model
        model.favoritesOnly = true
        model.query = "Planning"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        #expect(model.searchStarred)
        #expect(model.searchSpeakers == ["Alice", "Bob"])
        model.searchSpeaker = "Alice"
        await model.settle()
        #expect(Set(model.content.results!.map(\.id)) == Set([own, imported, document, recovered, old]))
        model.recordedByMe = true
        #expect(Set(model.content.results!.map(\.id)) == Set([own, recovered, old]))
        model.searchDate = .year
        #expect(Set(model.content.results!.map(\.id)) == Set([own, recovered]))
        model.searchStarred = false
        #expect(Set(model.content.results!.map(\.id)) == Set([own, recovered, unstarred]))
        #expect(!model.content.results!.contains { $0.id == unrelated })
        model.closeSearch()
        #expect(model.searchSpeaker == nil && model.searchDate == .any && !model.recordedByMe)
        #expect(model.searchStarred && model.favoritesOnly)
        #expect(model.content.results == nil)
        #expect(!model.content.sections.flatMap(\.rows).contains { $0.id == unstarred })
        model.beginSearch()
        #expect(model.searchStarred && model.searchSpeaker == nil)
        model.searchStarred = false
        model.closeSearch()
        #expect(model.favoritesOnly && model.searchStarred)
    }

    @Test func speakerSearchMatchesOnlyThatSpeakersRunsAndDeduplicatesNames() async {
        let library = Library()
        let meeting = library.add("Budget title")
        library.notes[0].speakers = [NoteSpeaker(id: "a", name: "Alice"), NoteSpeaker(id: "b", name: "Bob"),
                                     NoteSpeaker(id: "c", name: "alice"), NoteSpeaker(id: "p", name: "Speaker 4"),
                                     NoteSpeaker(id: "blank", name: "  ")]
        library.notes[0].transcript = [
            .init(text: "Hello everyone", start: 0, end: 1, speakerID: "a"),
            .init(text: "The budget belongs to Bob", start: 1, end: 2, speakerID: "b"),
            .init(text: "Hello again", start: 2, end: 3, speakerID: "c")]
        let model = library.model
        #expect(model.searchSpeakers == ["Alice", "Bob"])
        model.query = "budget"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        model.searchSpeaker = "ALICE"
        await model.settle()
        #expect(model.content.results?.isEmpty == true)
        model.searchSpeaker = "bob"
        await model.settle()
        #expect(model.content.results?.map(\.id) == [meeting])
        var index = LibraryIndex(library.notes)
        let hits = index.search(SearchQuery("budget"), speaker: "BOB")
        #expect(hits.first?.snippet.contains("belongs to Bob") == true)
        #expect(hits.first?.snippet.contains("Hello") == false)
        #expect(index.search(SearchQuery("hello again"), speaker: "Alice").count == 1)
        #expect(index.search(SearchQuery("hello everyone"), speaker: "alice").count == 1)
        #expect(index.search(SearchQuery("title"), speaker: "Alice").isEmpty)
        model.query = ""
        model.beginSearch()
        model.searchSpeaker = "alice"
        await model.settle()
        #expect(model.content.results?.map(\.id) == [meeting])
        model.searchSpeaker = "Speaker 4"
        await model.settle()
        #expect(model.content.results?.isEmpty == true)
    }

    @Test(arguments: ["?", "...", "---"])
    func punctuationOnlyQueriesApplyDateAndOriginButNeverInventSpeakerMatches(raw: String) async {
        let library = Library()
        let own = library.add("Own", "Hello")
        library.notes[0].speakers = [NoteSpeaker(id: "a", name: "Alice")]
        library.notes[0].transcript[0].speakerID = "a"
        _ = library.add("Imported", minutesAgo: 1)
        library.notes[1].origin = .imported
        _ = library.add("Yesterday", minutesAgo: 24 * 60)
        let model = library.model
        model.query = raw
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        model.recordedByMe = true
        model.searchDate = .today
        #expect(model.content.results?.map(\.id) == [own])
        model.searchSpeaker = "Alice"
        await model.settle()
        #expect(model.content.results?.isEmpty == true)
        #expect(model.content.facts.results == 0)
        #expect(model.content.emptyState == .noMatch(raw))
    }

    @Test func filterOnlySearchNeverShowsRestingLibraryEmptyStates() async {
        let library = Library()
        library.add("Starred yesterday", minutesAgo: 24 * 60)
        library.notes[0].isFavorite = true
        library.notes[0].origin = .imported
        let model = library.model
        model.favoritesOnly = true
        model.beginSearch()
        model.searchDate = .today
        await model.settle()
        #expect(model.content.facts.results == 0)
        #expect(model.content.emptyState == nil)
        model.searchStarred = false
        #expect(model.content.emptyState == nil)
        model.searchDate = .any
        model.recordedByMe = true
        #expect(model.content.facts.results == 0)
        #expect(model.content.emptyState == nil)
        model.recordedByMe = false
        model.searchSpeaker = "Bob"
        await model.settle()
        #expect(model.content.facts.results == 0)
        #expect(model.content.emptyState == nil)
    }

    @Test func firstTypedQueryHidesFilterOnlyPreloadDuringDebounce() async {
        let library = Library()
        let meeting = library.add("Budget")
        library.notes[0].isFavorite = true
        _ = library.add("Other")
        let model = library.model
        model.beginSearch()
        await model.settle()

        model.query = "zzz"
        #expect(model.content.results?.isEmpty == true)
        #expect(model.content.facts.results == nil)
        await waitUntilSleeping(library.clock)
        #expect(model.content.results?.isEmpty == true)
        #expect(model.content.facts.results == nil)
        library.clock.release()
        await model.settle()
        #expect(model.content.facts.results == 0)

        model.searchStarred = true
        model.query = ""
        // Clearing resets transient filters; a chip can immediately start another filter-only search.
        model.searchStarred = true
        #expect(model.content.results?.isEmpty == true)
        #expect(model.content.facts.results == nil)
        await model.settle()
        #expect(model.content.results?.map(\.id) == [meeting])
        #expect(model.content.facts.results == 1)
    }

    @Test func changingQueryKeepsPreviousHitsBeforeTheSearchAnswers() async {
        let library = Library()
        let meeting = library.add("Budget")
        let model = library.model
        model.query = "bud"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        #expect(model.content.results?.map(\.id) == [meeting])
        #expect(model.content.facts.results == 1)

        model.query = "budget"
        await waitUntilSleeping(library.clock)
        // Observe the old projection just before the new answer is published.
        // At that point the debounce has applied the new query, but found still holds the old hits.
        let checked = Mutex(false)
        withObservationTracking { _ = model.searched } onChange: {
            MainActor.assumeIsolated {
                withObservationTracking { _ = model.content } onChange: {
                    MainActor.assumeIsolated {
                        #expect(model.searched == "budget")
                        #expect(model.content.results?.map(\.id) == [meeting])
                        #expect(model.content.facts.query.isEmpty)
                        #expect(model.content.facts.results == nil)
                        #expect(model.content.emptyState == nil)
                        checked.withLock { $0 = true }
                    }
                }
            }
        }
        library.clock.release()
        await model.settle()
        #expect(checked.withLock { $0 })
        #expect(model.content.results?.map(\.id) == [meeting])
        #expect(model.content.facts.results == 1)
    }

    @Test func changingSpeakerHidesPreviousHitsBeforeTheSearchAnswers() async {
        let library = Library()
        let meeting = library.add("Alice meeting", "hello")
        library.notes[0].speakers = [NoteSpeaker(id: "a", name: "Alice")]
        library.notes[0].transcript[0].speakerID = "a"
        let model = library.model
        model.beginSearch()
        model.searchSpeaker = "Alice"
        await model.settle()
        #expect(model.content.results?.map(\.id) == [meeting])
        model.searchSpeaker = "Bob"
        // No actor suspension: the new task cannot have published yet.
        #expect(model.content.results?.isEmpty == true)
        #expect(model.content.facts.results == nil)
        #expect(model.content.emptyState == nil)
        await model.settle()
        #expect(model.content.results?.isEmpty == true)
    }

    @Test func recordedByMeIncludesRecoveredInFilterOnlySearch() async {
        let library = Library()
        let own = library.add("Own")
        let recovered = library.add("Recovered")
        library.notes[1].origin = .recovered
        _ = library.add("Imported")
        library.notes[2].origin = .imported
        let model = library.model
        model.beginSearch()
        model.recordedByMe = true
        await model.settle()
        #expect(Set(model.content.results!.map(\.id)) == Set([own, recovered]))
    }

    @Test func recordingTicksUpdateTheCardWithoutInvalidatingTheList() async throws {
        let library = Library()
        var note = Note(title: "Live", createdAt: library.clock.now)
        note.audio = .live; note.status = .recording
        library.notes = [note]
        var active = ActiveRecording(noteID: note.id, title: note.title, defaultTitle: note.title, format: .pcm48kMono)
        library.recording = .active(active)
        let model = library.model
        await model.settle()
        let initial = model.listContent
        let revision = model.presentationRevision
        let listChanged = Mutex(false), cardChanged = Mutex(false)
        withObservationTracking { _ = model.listContent } onChange: { listChanged.withLock { $0 = true } }
        withObservationTracking { _ = model.recordingCard } onChange: { cardChanged.withLock { $0 = true } }
        active.elapsed = 15
        library.recording = .active(active)
        await model.settle()
        #expect(!listChanged.withLock { $0 })
        #expect(cardChanged.withLock { $0 })
        #expect(model.presentationRevision == revision)
        #expect(model.recordingCard?.elapsed == 15)
        #expect(model.listContent == initial)
        library.recording = .finishing(noteID: note.id)
        await model.settle()
        #expect(listChanged.withLock { $0 }, "Lifecycle changes still refresh retained rows")
    }

    /// The view must observe these projections, rather than retain a pre-active row captured by a lazy builder.
    @Test func liveRecordingAndTimestampChangesInvalidateTheObservedRowProjection() async throws {
        let library = Library()
        var note = Note(title: "English live meeting", createdAt: library.clock.now)
        note.audio = .live
        note.status = .recording
        note.meetingTime = .unknown
        library.notes = [note]
        library.recording = .starting
        let model = library.model
        let initial = try #require(model.content.sections.flatMap(\.rows).first)
        #expect(initial.id == note.id)
        #expect(initial.status == .audioOnly)
        #expect(!initial.isRecording)
        #expect(initial.meetingTime == .unknown)
        #expect(model.recordingCard == nil)

        let initialRevision = model.presentationRevision
        let activeRowChanged = Mutex(false)
        let activeCardChanged = Mutex(false)
        _ = withObservationTracking { model.content } onChange: { activeRowChanged.withLock { $0 = true } }
        _ = withObservationTracking { model.recordingCard } onChange: { activeCardChanged.withLock { $0 = true } }
        library.recording = .active(ActiveRecording(noteID: note.id, title: note.title, defaultTitle: note.title,
                                                     format: .pcm48kMono, elapsed: 15))
        await model.settle()
        #expect(model.presentationRevision > initialRevision, "Capture changes must publish the model's own invalidation")
        #expect(activeRowChanged.withLock { $0 }, "Reading content must subscribe to recording-state changes")
        #expect(activeCardChanged.withLock { $0 }, "The card has its own live observation dependency")
        let active = try #require(model.content.sections.flatMap(\.rows).first)
        #expect(active.id == initial.id)
        #expect(active.status == .recording)
        #expect(active.isRecording)
        #expect(active.duration == 15)
        #expect(model.recordingCard?.noteID == note.id)
        #expect(model.recordingCard?.elapsed == 15)

        let activeRevision = model.presentationRevision
        let timestampChanged = Mutex(false)
        _ = withObservationTracking { model.content } onChange: { timestampChanged.withLock { $0 = true } }
        let recordedAt = library.clock.now.addingTimeInterval(90)
        library.notes[0].meetingTime = .instant(recordedAt)
        await model.settle() // The index publishes its revision after the notes' mutation event.
        #expect(model.presentationRevision > activeRevision)
        #expect(timestampChanged.withLock { $0 }, "A durable timestamp update must invalidate the row projection")
        let timestamped = try #require(model.content.sections.flatMap(\.rows).first)
        #expect(timestamped.id == initial.id, "Moving from an undated section never changes the note's identity")
        #expect(timestamped.meetingTime == .instant(recordedAt))
        #expect(timestamped.status == .recording)
        #expect(timestamped.isRecording)
        #expect(model.recordingCard?.noteID == timestamped.id)

        let timestampRevision = model.presentationRevision
        let endedRowChanged = Mutex(false)
        _ = withObservationTracking { model.content } onChange: { endedRowChanged.withLock { $0 = true } }
        library.recording = .ended(noteID: note.id, outcome: .saved(.audioOnly))
        await model.settle()
        #expect(model.presentationRevision > timestampRevision)
        #expect(endedRowChanged.withLock { $0 }, "Ending invalidates the same observed projection without editing notes")
        let ended = try #require(model.content.sections.flatMap(\.rows).first)
        #expect(ended.id == initial.id)
        #expect(ended.status == .audioOnly)
        #expect(!ended.isRecording)
        #expect(ended.meetingTime == .instant(recordedAt))
        #expect(model.recordingCard == nil)
    }

    @Test func queueChangesPublishRowInvalidationWithoutChangingTheNote() async throws {
        let library = Library()
        let id = library.add("English queue invalidation")
        let model = library.model
        let original = library.notes
        for state in [JobState.queued, .running, .paused] {
            let before = model.presentationRevision
            let changed = Mutex(false)
            _ = withObservationTracking { model.content } onChange: { changed.withLock { $0 = true } }
            library.processing.jobs[id] = Job(noteID: id, seq: 1, kind: .transcribe, state: state,
                                               doneMs: 500, language: "en", enqueuedAt: library.clock.now, updatedAt: library.clock.now)
            library.processing.running = state == .running ? RunningJob(noteID: id, title: "English queue invalidation") : nil
            await model.settle()
            #expect(model.presentationRevision > before)
            #expect(changed.withLock { $0 })
            #expect(library.notes == original, "The presentation refresh cannot depend on a note write")
            let row = try #require(model.content.sections.flatMap(\.rows).first)
            let expected: LibraryRow.Status = switch state {
            case .queued: .queued
            case .running: .transcribing
            default: .paused(atMs: 500)
            }
            #expect(row.status == expected)
        }
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
        await model.settle()
        #expect(model.searched == "fatt")
        let results = model.content.results ?? []
        #expect(results.map(\.id) == [hit])
        #expect(results.first?.titleRanges == [0..<7])
        #expect(model.content.sections.isEmpty)

        model.query = "zzz"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
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
        await model.settle()
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

    @Test func dateFiltersNarrowTextMatchesAndResetWhenSearchCloses() async throws {
        let library = Library()
        let today = library.add("English planning")
        let week = library.add("English planning last week", minutesAgo: 3 * 24 * 60)
        let month = library.add("English planning last month", minutesAgo: 20 * 24 * 60)
        library.add("English planning older", minutesAgo: 31 * 24 * 60)
        library.add("English planning tomorrow", minutesAgo: -24 * 60)
        library.add("Unrelated title")
        let model = library.model
        model.query = "English"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        model.searchDate = .month
        #expect(model.content.results?.map(\.id) == [today, week, month])
        model.searchDate = .week
        #expect(model.content.results?.map(\.id) == [today, week])
        model.searchDate = .today
        #expect(model.content.results?.map(\.id) == [today])
        let favorite = try #require(library.notes.firstIndex { $0.id == week })
        library.notes[favorite].isFavorite = true
        await model.settle()
        model.favoritesOnly = true
        #expect(model.content.results == [])
        model.searchDate = .week
        #expect(model.content.results?.map(\.id) == [week], "Date and Starred combine with AND")
        model.query = " "
        #expect(model.searchDate == .any)
        #expect(model.content.results == nil, "Without text, keep the normal Library")
        #expect(model.content.sections.flatMap(\.rows).map(\.id) == [week])
        #expect(Library().model.searchDate == .any, "Date filters are not persisted")
    }

    @Test func dateFiltersUseMeetingInstantOrWrittenLocalDayAndExcludeUnknownTimes() async throws {
        let library = Library()
        let today = library.add("English recorded today")
        let yesterday = library.add("English sealed today")
        let unknown = library.add("English unknown date")
        let local = library.add("English local date")
        let yesterdayIndex = try #require(library.notes.firstIndex { $0.id == yesterday })
        let unknownIndex = try #require(library.notes.firstIndex { $0.id == unknown })
        let localIndex = try #require(library.notes.firstIndex { $0.id == local })
        library.notes[yesterdayIndex].meetingTime = .instant(library.clock.now.addingTimeInterval(-86_400))
        library.notes[unknownIndex].meetingTime = .unknown
        library.notes[localIndex].meetingTime = .local("2026-10-08T09:41:00")
        let model = library.model
        model.query = "English"
        model.searchDate = .today
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        #expect(Set(model.content.results?.map(\.id) ?? []) == Set([today, local]), "Written local days are usable without inventing an instant; seal and catalogue dates are not")
        model.searchDate = .any
        #expect(Set(model.content.results?.map(\.id) ?? []) == Set([today, yesterday, unknown, local]))
    }

    @Test func dateFilterUsesInclusiveLocalStartAndExclusiveTomorrow() async throws {
        let library = Library()
        let now = library.clock.now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let midnight = calendar.startOfDay(for: now)
        let start = try #require(calendar.date(byAdding: .day, value: -6, to: midnight))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: midnight))
        let atStart = library.add("English start", minutesAgo: now.timeIntervalSince(start) / 60)
        library.add("English before", minutesAgo: now.timeIntervalSince(start.addingTimeInterval(-1)) / 60)
        let beforeEnd = library.add("English end", minutesAgo: now.timeIntervalSince(end.addingTimeInterval(-1)) / 60)
        library.add("English tomorrow", minutesAgo: now.timeIntervalSince(end) / 60)
        let model = library.model
        model.query = "English"
        model.searchDate = .week
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        #expect(model.content.results?.map(\.id) == [beforeEnd, atStart])
        model.searchDate = .any
        #expect(model.content.results?.count == 4)
    }

    /// A search left open across midnight: the clock moves, the query and the notes do not. The rows are read again
    /// only when `clockChanged()` sees a new local day, and then Today no longer holds yesterday's note.
    @Test func aNewLocalDayRedrawsAnOpenSearch() async throws {
        let library = Library()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let evening = try #require(calendar.date(bySettingHour: 23, minute: 50, second: 0, of: library.clock.now))
        library.clock.set(evening)
        let planning = library.add("English planning")
        let model = library.model
        model.query = "English"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        model.searchDate = .today
        #expect(model.content.results?.map(\.id) == [planning])

        let redrawn = Mutex(false)
        withObservationTracking { _ = model.content } onChange: { redrawn.withLock { $0 = true } }
        library.clock.set(evening.addingTimeInterval(5 * 60))
        model.clockChanged()
        #expect(!redrawn.withLock { $0 }, "the same day does not redraw")
        library.clock.set(evening.addingTimeInterval(20 * 60))
        #expect(!redrawn.withLock { $0 }, "nothing redraws before the day change is heard")
        model.clockChanged()
        #expect(redrawn.withLock { $0 }, "the new day redraws the open search")
        #expect(model.query == "English" && model.searchDate == .today)
        #expect(model.content.results == [])
        #expect(model.content.emptyState == .noMatch("English"))
        model.searchDate = .week
        #expect(model.content.results?.map(\.id) == [planning], "yesterday's note is still within the week")
    }

    @Test func clearingBeforeDebounceAlsoClearsTheDateFilter() async {
        let library = Library(), model = library.model
        model.query = "English"
        await waitUntilSleeping(library.clock)
        model.searchDate = .week
        model.query = ""
        #expect(model.searchDate == .any)
        library.clock.release()
        await model.settle()
        #expect(model.content.results == nil)
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
    @Test func theStarredFilterKeepsOnlyStarredNotes() async {
        let library = Library()
        library.add("plain")
        let starred = library.add("starred")
        library.notes[library.notes.firstIndex { $0.id == starred }!].isFavorite = true
        library.model.favoritesOnly = true
        #expect(library.model.content.sections.flatMap(\.rows).map(\.id) == [starred])
        library.notes.removeAll { $0.id == starred }
        await library.model.settle()
        #expect(library.model.content.emptyState == .noStarred)
    }


    // MARK: The actions menu

    private func document(_ library: Library, _ title: String, _ state: DocumentState) -> UUID {
        let id = library.add(title, "one two three")
        let index = library.notes.firstIndex { $0.id == id }!
        library.notes[index].status = .ready
        library.notes[index].document = DocumentInfo(state: state)
        return id
    }

    // ports: LibraryViewModelTest#longPressOpensTheActionsSheetAndItsRows
    @Test func longPressOpensTheActionsSheetAndItsRows() async {
        let library = Library()
        let queued = library.add("Queued one")
        library.processing.jobs[queued] = Job(noteID: queued, seq: 1, kind: .transcribe, state: .queued,
                                              enqueuedAt: library.clock.now)
        let model = library.model
        #expect(model.menu(queued)?.transcribe == .removeFromQueue)
        await model.perform(.removeFromQueue, on: queued)
        #expect(model.dialog == nil)
        #expect(library.actions == ["dequeue Queued one"])

        await model.perform(.rename, on: queued)
        #expect(model.dialog == .rename(queued))
        #expect(model.rename(queued, to: "   ") == false, "a blank title keeps the dialog open")
        #expect(model.dialog == .rename(queued))
        #expect(model.rename(queued, to: "  Renamed  "))
        #expect(model.dialog == nil)
        #expect(library.actions.last == "update Renamed")
        #expect(library.notes.first { $0.id == queued }?.title == "Renamed")
        await model.settle()
        #expect(model.rename(queued, to: "Renamed"))
        #expect(library.actions.count == 2, "an unchanged title is not saved again")

        library.processing.jobs[queued]?.state = .paused
        #expect(model.menu(queued)?.transcribe == .resumeOrStartOver)
        await model.perform(.startOver, on: queued)
        #expect(model.dialog == .startOver(queued))
        await model.confirmDialog()
        #expect(model.dialog == nil)
        #expect(library.actions.last == "startOver Renamed")
    }

    /// Start over's outcome is handled as Transcribe's: the model download without consent, the reason on a refusal.
    @Test func startOverWithoutConsentOpensTheModelDownloadAndARefusalSaysWhy() async {
        let library = Library()
        let paused = library.add("p")
        let model = library.model
        library.outcome = .needsConsent
        await model.perform(.startOver, on: paused)
        await model.confirmDialog()
        library.outcome = .refused(.unplayable)
        await model.perform(.startOver, on: paused)
        await model.confirmDialog()
        #expect(library.effects == [.openModelDownload(noteID: paused), .refused(.unplayable)])
        #expect(library.actions == ["startOver p", "startOver p"])

        await model.perform(.startOver, on: paused)
        model.dismissDialog()
        await model.confirmDialog()
        #expect(library.actions.count == 2, "Cancel starts nothing over")
    }

    // ports: LibraryViewModelTest#exportRowsOpenTheNoteScreenWithTheRowToStart
    @Test func exportRowsOpenTheNoteScreenWithTheRowToStart() async {
        let library = Library()
        let doc = document(library, "d", .ok)
        let model = library.model
        #expect(model.menu(doc)?.export == .available)
        await model.perform(.export(.text), on: doc)
        await model.perform(.documentInfo, on: doc)
        await model.perform(.export(.webVTT), on: doc)
        await model.perform(.exportDocument, on: doc)
        await model.perform(.shareAudio, on: doc)
        #expect(library.effects == [.openNote(.note(doc, start: .export(.text))), .openNote(.note(doc, start: .documentInfo)),
                                    .openNote(.note(doc, start: .export(.webVTT))), .openNote(.note(doc, start: .exportDocument)),
                                    .openNote(.note(doc, start: .shareAudio))])
        #expect(model.dialog == nil)
        #expect(model.menu(doc)?.exportsDocument == true)
    }

    // ports: LibraryViewModelTest#transcribeAgainOnAChangedDocumentConfirmsAFreshOne
    @Test func transcribeAgainOnAChangedDocumentConfirmsAFreshOne() async {
        let library = Library()
        let stale = document(library, "s", .staleAudio)
        let model = library.model
        await model.perform(.transcribeAgain, on: stale)
        #expect(model.dialog == .transcribeFresh(stale))
        #expect(library.actions.isEmpty)
        await model.confirmDialog()
        #expect(library.actions == ["transcribe s transcribeAgain"])

        let ok = document(library, "ok", .ok)
        await model.settle()
        await model.perform(.transcribeAgain, on: ok)
        #expect(model.dialog == nil, "a document that keeps its versions transcribes at once")
        #expect(library.actions.last == "transcribe ok transcribeAgain")

        let unverified = document(library, "u", .unverified)
        await model.settle()
        #expect(model.menu(unverified)?.transcribe == .transcribeAgainUnavailable)
        await model.perform(.transcribeAgain, on: unverified)
        #expect(library.actions.count == 2, "a file that cannot take a new version is not queued")
    }

    /// Stop, Resume with the job's kind, Star, Move to Recently Deleted, and the menu of a note being recorded.
    @Test func theOtherMenuRowsReachTheirPorts() async {
        let library = Library()
        let running = library.add("r")
        library.processing.jobs[running] = Job(noteID: running, seq: 1, kind: .transcribeAgain, state: .running,
                                               enqueuedAt: library.clock.now)
        var live = Note(title: "Standup")
        live.audio = .live
        library.notes.append(live)
        library.recording = .active(ActiveRecording(noteID: live.id, title: "Standup", defaultTitle: "", format: .pcm48kMono))
        library.finishing = live.id
        library.speakerModelsReady = true
        let model = library.model
        await model.refreshSpeakerModels()
        #expect(model.speakerModelsReady)
        #expect(model.menu(running)?.transcribe == .stop)
        await model.perform(.stop, on: running)
        library.processing.jobs[running]?.state = .paused
        await model.perform(.resume, on: running)
        await model.perform(.toggleStar, on: running)
        await model.settle()
        #expect(model.menu(running)?.isFavorite == true)
        await model.perform(.moveToTrash, on: running)
        #expect(library.actions == ["stop r", "transcribe r transcribeAgain", "update r", "trash r"])

        let menu = model.menu(live.id)
        #expect(menu?.recording == true)
        #expect(menu?.transcribeWaits == true)
        #expect(menu?.export == .afterTranscription)
        #expect(model.menu(UUID()) == nil)
    }

    // MARK: Search over changing notes

    /// A note trashed or renamed while a search runs: the results show the notes as they are now.
    @Test func resultsFollowTheNotesWhileTheSearchRunsAgain() async {
        let library = Library()
        let keep = library.add("Fattura uno", minutesAgo: 1)
        let gone = library.add("Fattura due")
        let model = library.model
        model.query = "fatt"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        #expect(model.content.results?.map(\.id) == [gone, keep])

        library.notes.removeAll { $0.id == gone }
        library.notes[library.notes.firstIndex { $0.id == keep }!].title = "Fattura rinominata"
        while model.note(gone) != nil { await Task.yield() } // the index has the new notes; the search may not yet
        let rows = model.content.results ?? []
        #expect(rows.map(\.id) == [keep], "a note that went is never a row")
        #expect(rows.first?.title == "Fattura rinominata")
        await model.settle()
        #expect(model.content.results?.map(\.id) == [keep])
    }

    /// Notes that keep changing never starve the search: a search over old notes still answers, then runs again.
    @Test func aSearchAnswersWhileTheNotesKeepChanging() async {
        let library = Library()
        library.add("Fattura")
        let model = library.model
        model.query = "fatt"
        await waitUntilSleeping(library.clock)
        library.clock.release()
        for step in 0..<5 {
            library.add("Fattura \(step)")
            await Task.yield()
        }
        await model.settle()
        #expect(model.content.results?.count == 6)
    }

    // MARK: Wave 5 first-run hero (D-974)

    // ports: LibraryViewModelTest#groupsTheLibraryByDayAndShowsTheFirstRunHeroInsteadOfTheEmptyBanner
    @Test func showsTheFirstRunHeroOnAnEmptyLibraryAndHidesItOnceANoteExists() async {
        let library = Library()
        let model = library.model
        #expect(model.content.emptyState == .empty)
        #expect(model.content.hero == FirstRunHero(cloudBackup: true, privacy: .withBackup))

        library.add("Today note", minutesAgo: 0)
        library.add("Yesterday note", minutesAgo: 24 * 60)
        await model.settle()
        #expect(model.content.hero == nil)
        #expect(model.content.emptyState == nil)
        #expect(model.content.sections.map(\.key) == [.today, .yesterday])
    }

    // ports: LibraryViewModelTest#theFirstRunHeroFollowsEveryAutomaticCopyThatCanLeaveThePhone
    @Test func theFirstRunHeroFollowsIOSBackupStateAndObservesChanges() async {
        let library = Library()
        let model = library.model
        let before = model.presentationRevision
        #expect(model.content.hero == FirstRunHero(cloudBackup: true, privacy: .withBackup))

        library.cloudBackup = false
        await model.settle()
        #expect(model.presentationRevision != before)
        #expect(model.content.hero == FirstRunHero(cloudBackup: false, privacy: .backupExcluded))

        library.cloudBackup = true
        await model.settle()
        #expect(model.content.hero == FirstRunHero(cloudBackup: true, privacy: .withBackup))
    }

    // ports: LibraryViewModelTest#noPrivacyClaimIsDrawnBeforeTheBackupChoicesAreRead
    @Test func noPrivacyClaimIsDrawnBeforeTheBackupStateIsRead() async {
        let library = Library()
        library.cloudBackup = nil
        let model = library.model
        #expect(model.content.hero == nil)

        library.cloudBackup = false
        await model.settle()
        #expect(model.content.hero == FirstRunHero(cloudBackup: false, privacy: .backupExcluded))
    }

    // ports: LibraryViewModelTest#searchingAnEmptyLibraryShowsNoHero
    @Test func searchingAnEmptyLibraryShowsNoHeroBeforeOrAfterDebounce() async {
        let library = Library()
        let model = library.model
        #expect(model.content.hero != nil)

        model.query = "budget"
        #expect(model.content.hero == nil, "no hero while typing before the debounce")
        await waitUntilSleeping(library.clock)
        library.clock.release()
        await model.settle()
        #expect(model.content.hero == nil)
        #expect(model.content.emptyState == .noMatch("budget"))
    }

    private func waitUntilSleeping(_ clock: GatedClock, count: Int = 1) async {
        while clock.sleeping < count { await Task.yield() }
    }
}
