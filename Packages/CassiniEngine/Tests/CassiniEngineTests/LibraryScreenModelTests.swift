import Foundation
import Synchronization
import Testing
import CassiniCore
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

    @Test func dateFiltersUseMeetingInstantAndExcludeUnknownOrUnzonedTimes() async throws {
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
        #expect(model.content.results?.map(\.id) == [today], "Seal and catalogue dates do not establish a meeting date")
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

    private func waitUntilSleeping(_ clock: GatedClock, count: Int = 1) async {
        while clock.sleeping < count { await Task.yield() }
    }
}
