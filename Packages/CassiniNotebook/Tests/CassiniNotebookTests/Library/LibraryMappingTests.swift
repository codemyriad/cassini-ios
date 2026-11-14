import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android `LibraryMappingTest`: status chips, day groups, previews, banner inputs and the actions' transcribe item.
struct LibraryMappingTests {
    private static let rome: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()
    private var rome: Calendar { Self.rome }
    /// 8 Oct 2026 10:00 in Rome.
    private let now = Self.daysAgo(0, 10, 0)

    private static func daysAgo(_ days: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        let day = rome.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: hour, minute: minute))!
        return rome.date(byAdding: .day, value: -days, to: day)!
    }

    private func note(_ title: String = "Note", createdAt: Date? = nil, audio: AudioState = .plain) -> Note {
        var note = Note(title: title, createdAt: createdAt ?? now)
        note.audio = audio
        return note
    }

    private func transcribed(_ title: String = "Doc", _ state: DocumentState? = nil, speakers: Int = 1, words: Bool = true) -> Note {
        var note = note(title)
        note.status = .ready
        note.transcript = words ? (0..<max(1, speakers)).map { TranscriptSegment(text: "word \($0)", start: Double($0), end: Double($0) + 1, speakerID: "s\($0)") } : []
        note.document = state.map { DocumentInfo(state: $0) }
        return note
    }

    private func job(_ id: UUID, _ state: JobState, kind: JobKind = .transcribe, doneMs: Int64 = 0, failure: JobFailure? = nil) -> Job {
        Job(noteID: id, seq: 1, kind: kind, state: state, failure: failure, doneMs: doneMs, enqueuedAt: now)
    }

    private func entry(_ note: Note) -> LibraryIndex.Entry { LibraryIndex([note]).entries[0] }

    // ports: LibraryMappingTest#statusChipForEveryRow
    @Test func statusChipForEveryRow() {
        let rec = note("rec", audio: .live), run = note("tx"), queued = note("q"), paused = note("p"), failed = note("f")
        let consent = note("c")
        let jobs = [job(run.id, .running), job(queued.id, .queued), job(paused.id, .paused, doneMs: 760_000), job(failed.id, .failed),
                    job(consent.id, .needsConsent)]
        let active = RowContext(activeNoteID: rec.id, jobs: Dictionary(uniqueKeysWithValues: jobs.map { ($0.noteID, $0) }))
        let cases: [(Note, LibraryRow.Status)] = [
            (rec, .recording),
            (run, .transcribing),
            (queued, .queued),
            (paused, .paused(atMs: 760_000)),
            (failed, .failed),
            (note("u", audio: .unplayable(.interrupted)), .unplayable),
            (transcribed("r", .unreadable), .unreadable),
            (transcribed("m", .invalidMetadata), .unreadable),
            (transcribed("n", .unknownFormat), .newerFormat),
            (transcribed("t", .ok, speakers: 3), .transcribed(speakers: 3, hasWords: true)),
            (transcribed("s", .staleAudio, speakers: 0, words: false), .transcribed(speakers: 0, hasWords: false)),
            (note("a"), .audioOnly),
            (consent, .audioOnly),
            // A live capture that is not the active one (recovery has not run yet) is not "Recording".
            (note("old", audio: .live), .audioOnly),
        ]
        for (note, status) in cases {
            #expect(LibraryMapping.row(entry(note), context: active).status == status, "\(note.title)")
        }
    }

    // ports: LibraryMappingTest#groupsByLocalDayNewestFirst
    @Test func groupsByLocalDayNewestFirst() {
        let notes = [note("today2", createdAt: Self.daysAgo(0, 9, 30)), note("today1", createdAt: Self.daysAgo(0, 0, 5)),
                     note("yesterday", createdAt: Self.daysAgo(1, 23, 50)), note("monday", createdAt: Self.daysAgo(3)),
                     note("lastYear", createdAt: Self.daysAgo(400))]
        let sections = LibraryMapping.sections(LibraryIndex(notes).entries, context: RowContext(), now: now, calendar: rome)
        #expect(sections.map(\.key) == [.today, .yesterday,
                                        .date(CalendarDay(year: 2026, month: 10, day: 5), withYear: false),
                                        .date(CalendarDay(year: 2025, month: 9, day: 3), withYear: true)])
        #expect(sections[0].rows.map(\.title) == ["today2", "today1"])
        #expect(sections[0].rows[0].createdAt == Self.daysAgo(0, 9, 30))
        #expect(sections[0].rows[0].day == nil, "day sections carry the day in the header")
    }

    // ports: LibraryMappingTest#runningAndRecordingRows
    @Test func runningAndRecordingRows() {
        let rec = note("rec", audio: .live), running = note("run")
        let live = RowContext(activeNoteID: rec.id, recordingElapsed: 1_447, runningNoteID: running.id)
        let recRow = LibraryMapping.row(entry(rec), context: live)
        #expect(recRow.duration == 1_447)
        #expect(recRow.isRecording)
        #expect(!recRow.highlighted)
        #expect(LibraryMapping.row(entry(running), context: live).highlighted)
        #expect(LibraryMapping.row(entry(running), context: live).status == .transcribing)
    }

    @Test func ordinaryRowsOmitTheVisualQuoteWhileSearchRetainsItsMarkedSnippet() {
        var value = transcribed("English planning", speakers: 1)
        value.transcript = [TranscriptSegment(text: "English meeting context", start: 0, end: 2, speakerID: "a")]
        let normal = LibraryMapping.row(entry(value), context: RowContext())
        #expect(normal.status == .transcribed(speakers: 1, hasWords: true))
        #expect(normal.status.suffix == .speakers)
        #expect(normal.preview != nil, "The existing spoken row context is retained")
        #expect(normal.displayedPreview == nil)
        let snippet = Highlighted("matching English context", ranges: [9..<16], leadingEllipsis: true)
        let result = LibraryMapping.row(entry(value), context: RowContext(),
                                       hit: .init(day: .today, title: nil, snippet: snippet))
        #expect(result.displayedPreview == snippet)
        #expect(result.preview == snippet)
        #expect(result.id == normal.id)
        #expect(result.status == normal.status)
        let titleOnly = LibraryMapping.row(entry(value), context: RowContext(),
                                          hit: .init(day: .today, title: "English planning", snippet: nil))
        #expect(titleOnly.displayedPreview == nil, "A title-only search result does not restore the ordinary quote")
    }

    // ports: LibraryMappingTest#searchResultsHighlightTitleAndSnippet
    @Test func searchResultsHighlightTitleAndSnippet() {
        let a = note("Call with supplier", createdAt: Self.daysAgo(1)), b = note("Invoice March")
        let hits = [LibraryIndex.Hit(entry: entry(a), snippet: "…the \u{2}delivery\u{3} slips…", titleSnippet: "Call with supplier"),
                    LibraryIndex.Hit(entry: entry(b), snippet: "no markers here", titleSnippet: "\u{2}Invoice\u{3} March")]
        let results = LibraryMapping.results(hits, context: RowContext(), now: now, calendar: rome)
        #expect(results.map(\.id) == [b.id, a.id], "Search displays meeting order rather than incoming hit order")
        let first = results[1]
        #expect(first.day == .yesterday)
        #expect(first.preview == Highlighted("the delivery slips", ranges: [4..<12], leadingEllipsis: true, trailingEllipsis: true))
        #expect(first.titleRanges.isEmpty)
        let second = results[0]
        #expect(second.title == "Invoice March")
        #expect(second.titleRanges == [0..<7])
        #expect(second.preview == nil, "a title-only match shows no snippet")
        #expect(second.day == .today)
    }

    /// A title that the 64-token snippet cut shows plain, without ranges.
    @Test func aCutTitleIsShownPlain() {
        let title = (1...70).map { "t\($0)" }.joined(separator: " ")
        var index = LibraryIndex([note(title)])
        let results = LibraryMapping.results(index.search(SearchQuery("t70")), context: RowContext(), now: now, calendar: rome)
        #expect(results.map(\.title) == [title])
        #expect(results[0].titleRanges.isEmpty)
    }

    // ports: LibraryMappingTest#storedPreviewKeepsItsEllipsesAndCutsTheFallbackAtAWord
    @Test func storedPreviewKeepsItsEllipsesAndCutsTheFallbackAtAWord() throws {
        #expect(LibraryMapping.storedPreview("…so the delivery slips…")
            == Highlighted("so the delivery slips", leadingEllipsis: true, trailingEllipsis: true))
        #expect(LibraryMapping.storedPreview("Short transcript.") == Highlighted("Short transcript."))
        #expect(LibraryMapping.storedPreview(nil) == nil)
        #expect(LibraryMapping.storedPreview("") == nil)
        let body = String(String(repeating: "sample ", count: 30).prefix(160))
        let cut = try #require(LibraryMapping.storedPreview(body))
        #expect(cut.trailingEllipsis)
        #expect(!cut.text.hasSuffix(" "))
        #expect(cut.text.count < 160 && body.hasPrefix(cut.text))
        #expect(cut.text.hasSuffix("sample"))
    }

    /// The row shows the preview at the saved position, from the transcript shown; a stored preview is read only
    /// for a note without a transcript.
    @Test func theRowPreviewComesFromTheTranscriptShown() {
        var note = transcribed("t", speakers: 1)
        note.transcript = [TranscriptSegment(text: "Good morning everyone.", start: 0, end: 2)]
        #expect(entry(note).preview == Highlighted("Good morning everyone."))
        note.previewText = "…stored…"
        #expect(entry(note).preview == Highlighted("Good morning everyone."), "a stored preview never hides the transcript")
        note.transcript = []
        #expect(entry(note).preview == Highlighted("stored", leadingEllipsis: true, trailingEllipsis: true))
    }

    /// Android `NoteDao.selectVariant` writes the preview with the body: a stored preview from the old version, or
    /// from before Transcribe again, never stays on the row.
    @Test func aStalePreviewFollowsTheSelectedVersion() throws {
        var note = transcribed("t", speakers: 1)
        note.transcript = [TranscriptSegment(text: "First take of the meeting.", start: 0, end: 2)]
        note.saveCurrentVersion(.transcription)
        let first = try #require(note.selectedVersionID)
        note.transcript = [TranscriptSegment(text: "Second take, transcribed again.", start: 0, end: 2)]
        note.saveCurrentVersion(.speakerAnalysis)
        note.previewText = PreviewText.of(note.transcript.flatMap(PreviewWord.of), positionMs: 0)?.display
        var index = LibraryIndex([note])
        #expect(index.entries[0].preview?.text == "Second take, transcribed again.")

        note.selectVersion(first)
        index.update([note])
        #expect(note.previewText?.contains("Second") == true, "the stored preview is from the other version")
        #expect(index.entries[0].preview?.text == "First take of the meeting.")
    }

    /// VoiceOver hears the banner at each stage change and each 5 % step, a download's and a check's included.
    @Test func theBannerIsAnnouncedAtEachStageAndFivePercentStep() {
        let id = UUID()
        func banner(_ line: ProgressBanner.Line, percent: Int? = nil, title: String? = "Weekly") -> ProgressBanner {
            ProgressBanner(noteID: id, title: title, percent: percent, fraction: nil, line: line, queued: 0)
        }
        let start = banner(.timeLeft(.calculating)).announcement
        #expect(banner(.waiting).announcement != start, "waiting for the previous note is a stage of its own")
        #expect(banner(.timeLeft(.range(lowMs: 1, highMs: 2))).announcement == start, "a new estimate is not")
        #expect(banner(.timeLeft(.finishing)).announcement != start, "finishing is")
        #expect(banner(.timeLeft(.calculating), percent: 3).announcement == start.with(step: 0))
        #expect(banner(.timeLeft(.calculating), percent: 4).announcement == banner(.timeLeft(.calculating), percent: 1).announcement)
        #expect(banner(.timeLeft(.calculating), percent: 5).announcement.step == 5)
        let speech = banner(.downloading(.speech, percent: 46)).announcement
        #expect(speech.step == 45, "the download's own percent")
        #expect(banner(.downloading(.speech, percent: 49)).announcement == speech)
        #expect(banner(.downloading(.speakers, percent: 46)).announcement != speech)
        #expect(banner(.checking(percent: 46)).announcement.stage == .checking)
        #expect(banner(.checking(percent: 46)).announcement != speech)
    }

    // ports: LibraryMappingTest#transcriptionBannerInputs
    @Test func transcriptionBannerInputs() {
        #expect(LibraryMapping.progress(ProcessingState(), phase: nil) == nil)
        let progress = RunningProgress(headline: .findingWords, percent: 62, step: .words, speakersSkipped: false,
                                       timeLeft: .range(lowMs: 360_000, highMs: 540_000), doneMs: 1, totalMs: 2,
                                       battery: .unavailable, words: 10)
        let n1 = UUID(), q1 = UUID()
        let transcribing = ProcessingState(running: RunningJob(noteID: n1, title: "Weekly"), queue: [q1])
        #expect(LibraryMapping.progress(transcribing, phase: .transcribing(progress, .empty))
            == ProgressBanner(noteID: n1, title: "Weekly", percent: 62, fraction: 0.62,
                              line: .timeLeft(.range(lowMs: 360_000, highMs: 540_000)), queued: 1))
        var waiting = transcribing
        waiting.queue = []
        #expect(LibraryMapping.progress(waiting, phase: .waitingForPrevious)?.line == .waiting)
        #expect(LibraryMapping.progress(waiting, phase: .waitingForPrevious)?.queued == 0)
        #expect(LibraryMapping.progress(waiting, phase: .starting)?.line == .timeLeft(.calculating))
        #expect(LibraryMapping.progress(waiting, phase: nil)?.line == .timeLeft(.calculating), "before the first report")
        #expect(LibraryMapping.progress(waiting, phase: .stopping())?.line == .timeLeft(.finishing))
        #expect(LibraryMapping.progress(waiting, phase: .stopping(StoppingProgress(progress: progress, draft: .empty)))?.line == .timeLeft(.finishing))
        let download = DownloadProgress(part: .speech, doneBytes: 46, totalBytes: 100, verifying: false)
        let downloading = LibraryMapping.progress(waiting, phase: .downloading(download))
        #expect(downloading?.line == .downloading(.speech, percent: 46))
        #expect(downloading?.isPreparing == true)
        #expect(downloading?.fraction == 0.46)
        var checking = download
        checking.doneBytes = 80; checking.verifying = true
        #expect(LibraryMapping.progress(waiting, phase: .downloading(checking))?.line == .checking(percent: 80))
        var speakers = progress
        speakers.download = DownloadProgress(part: .speakers, doneBytes: 46, totalBytes: 100, verifying: false)
        #expect(LibraryMapping.progress(waiting, phase: .transcribing(speakers, .empty))?.line == .downloading(.speakers, percent: 46))

        let standalone = LibraryMapping.progress(ProcessingState(), phase: nil,
                                                 install: DownloadFact(part: .speech, fraction: 0.46, at: now))
        #expect(standalone?.noteID == nil, "a standalone download opens Settings")
        #expect(standalone?.title == nil, "\"Downloading models\"")
        #expect(standalone?.line == .downloading(.speech, percent: 46))
        #expect(LibraryMapping.progress(ProcessingState(), phase: nil,
                                        install: DownloadFact(part: .speech, failure: .noConnection, at: now)) == nil)
    }

    // ports: LibraryMappingTest#recordingCard
    @Test func recordingCard() {
        #expect(LibraryMapping.recordingCard(.idle) == nil)
        let id = UUID()
        var active = ActiveRecording(noteID: id, title: "", defaultTitle: "Voice note 8 Oct, 08:14", format: .pcm48kMono,
                                     elapsed: 1_447)
        #expect(LibraryMapping.recordingCard(.active(active))
            == .init(noteID: id, title: "Voice note 8 Oct, 08:14", elapsed: 1_447, paused: false))
        active.title = "Standup"; active.pause = .user
        #expect(LibraryMapping.recordingCard(.active(active)) == .init(noteID: id, title: "Standup", elapsed: 1_447, paused: true))
    }

    // ports: LibraryMappingTest#actionsSheetRows
    @Test func actionsSheetRows() {
        let plain = note("p")
        #expect(LibraryMapping.transcribeAction(plain, job: nil, voiceModelReady: true) == .transcribe)

        var doc = transcribed("d", .ok, speakers: 2)
        doc.speakers = [NoteSpeaker(id: "s0", name: "Luca"), NoteSpeaker(id: "s1", name: DefaultLabels.placeholder(2))]
        #expect(LibraryMapping.transcribeAction(doc, job: nil, voiceModelReady: true) == .transcribeAgain(nextVersion: 2, namesCarry: true))
        #expect(LibraryMapping.transcribeAction(doc, job: nil, voiceModelReady: false) == .transcribeAgain(nextVersion: 2, namesCarry: false),
                "names carry over only through voiceprints")
        for state in [DocumentState.unverified, .unknownFormat] {
            var refused = doc
            refused.document = DocumentInfo(state: state)
            #expect(LibraryMapping.transcribeAgainRefused(refused), "\(state)")
            #expect(LibraryMapping.transcribeAction(refused, job: nil, voiceModelReady: true) == .transcribeAgainUnavailable)
        }
        #expect(!LibraryMapping.transcribeAgainRefused(doc))

        let states: [JobState: TranscribeAction] = [.running: .stop, .queued: .removeFromQueue, .paused: .resumeOrStartOver,
                                                    .failed: .transcribe]
        for (state, action) in states {
            #expect(LibraryMapping.transcribeAction(plain, job: job(plain.id, state), voiceModelReady: true) == action, "\(state)")
        }

        let unreadable = transcribed("u", .unreadable)
        #expect(LibraryMapping.needsFreshConfirmation(unreadable))
        #expect(!LibraryMapping.needsFreshConfirmation(doc))
    }

    /// Android `Notices.finalFailure`: too long, a refused document, or a new version the file cannot take.
    @Test func finalFailuresOpenTheNote() {
        let id = UUID()
        #expect(LibraryMapping.isFinalFailure(job(id, .failed, failure: .long), noNewVersion: false))
        #expect(LibraryMapping.isFinalFailure(job(id, .failed, failure: .documentRefused(.unknownFormat)), noNewVersion: false))
        #expect(LibraryMapping.isFinalFailure(job(id, .failed, kind: .transcribeAgain, failure: .audio), noNewVersion: true))
        #expect(!LibraryMapping.isFinalFailure(job(id, .failed, failure: .audio), noNewVersion: true))
        #expect(!LibraryMapping.isFinalFailure(job(id, .paused, failure: .long), noNewVersion: false))
    }

    /// Android `Notices.library`'s Library states: unavailable first, empty only once read, then no match.
    @Test func emptyStates() {
        #expect(LibraryMapping.emptyState(LibraryFacts(unavailable: true)) == .unavailable)
        #expect(LibraryMapping.emptyState(LibraryFacts(loading: true)) == nil)
        #expect(LibraryMapping.emptyState(LibraryFacts()) == .empty)
        #expect(LibraryMapping.emptyState(LibraryFacts(liveNotes: 3, query: "zzz", results: 0)) == .noMatch("zzz"))
        #expect(LibraryMapping.emptyState(LibraryFacts(liveNotes: 3, query: "zzz", results: nil)) == nil, "not answered yet")
        #expect(LibraryMapping.emptyState(LibraryFacts(liveNotes: 3, results: 3)) == nil)
        #expect(LibraryMapping.emptyState(LibraryFacts(liveNotes: 3, results: 0), favoritesOnly: true) == .noStarred)
    }
}

private extension ProgressBanner.Announcement {
    func with(step: Int?) -> Self { var copy = self; copy.step = step; return copy }
}

extension LibraryMappingTests {
    @Test func standaloneVerificationDoesNotReuseTheCompletedTransferPercent() throws {
        let fact = DownloadFact(part: .speakers, fraction: 1, checking: true, at: Date(timeIntervalSince1970: 0))
        let banner = try #require(LibraryMapping.progress(ProcessingState(), phase: nil, install: fact))
        #expect(banner.line == .checking(percent: nil))
        #expect(banner.stage == .checking)
        #expect(banner.isPreparing)
        #expect(banner.noteID == nil && banner.title == nil)
        #expect(banner.fraction == nil && banner.spokenPercent == nil,
                "Completed download bytes are not verification/decompression progress")
    }

    @Test(arguments: [Int64(0), -1])
    func modelCheckingWithoutAMeasuredTotalHasNoPercentage(_ total: Int64) throws {
        let id = UUID()
        let state = ProcessingState(running: RunningJob(noteID: id, title: "Weekly sync"))
        let progress = DownloadProgress(part: .speakers, doneBytes: 100, totalBytes: total, verifying: true)
        let banner = try #require(LibraryMapping.progress(state, phase: .downloading(progress)))
        #expect(banner.line == .checking(percent: nil))
        #expect(banner.fraction == nil)
        #expect(banner.spokenPercent == nil)
    }
}
