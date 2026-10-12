import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The job against a scripted transcriber over 70 s of audio: one 5 s result after another, one word a second.
@Suite struct TranscriptionJobTests {
    // ports: TranscriptionJobTest#decodesIn28SecondWindowsAndSavesOneCheckpointPerWindow
    @Test func savesACheckpointEvery30SecondsOfFinalAudio() async throws {
        let h = try await Harness()
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(h.checkpoints.saved.map(\.doneMs) == [30_000, 60_000, 70_000])
        #expect(h.checkpoints.saved.map(\.wordsComplete) == [false, false, true])
        #expect(events.compactMap(\.checkpointed) == [30_000, 60_000, 70_000])
        #expect(events.first?.isStarted == true)
        #expect(events.last == .ended(.done))
        #expect(events.compactMap(\.stage).uniqued() == [.reading, .preparing, .words, .speakers, .matching, .saving])
        let closed = try #require(events.firstIndex(of: .namingClosed(matching: true)))
        #expect(closed > events.lastIndex { $0.checkpointed != nil }!)
        let note = try #require(await h.note())
        #expect(note.transcript.flatMap(\.draftWords).map(\.text) == (0..<70).map { "w\($0)" })
        #expect(note.versions?.last?.name == "On-device transcription")
        #expect(note.provenance?.engine == "apple-speechtranscriber")
        #expect(h.applied.count == 1)
        #expect(!h.files.exists(h.noteID), "the work is removed once the note is saved")
    }

    // ports: TranscriptionJobTest#checkpointsOnlyCountWhatWasFsynced
    @Test func checkpointsOnlyCountWhatIsOnDisk() async throws {
        let h = try await Harness()
        let files = h.files, noteID = h.noteID
        let mismatches = Mutex<[Int64]>([])
        let (outcome, _) = await h.run { event in
            guard case .checkpointed(let doneMs) = event else { return }
            let stored = try? files.load(noteID)
            if stored?.doneMs != doneMs { mismatches.withLock { $0.append(doneMs) } }
        }
        #expect(outcome == .done)
        #expect(mismatches.withLock { $0 }.isEmpty)
        let first = try #require(h.checkpoints.saved.first)
        #expect(first.source == "audio.m4a")
        #expect(first.signature == CheckpointState.signature(of: h.audioURL))
        #expect(first.language == "it-IT")
    }

    // ports: TranscriptionJobTest#withoutAContainerDurationTheRowsDurationIsTheTotal
    @Test func withoutADurationFromTheFileTheNotesDurationIsTheTotal() async throws {
        let known = try await Harness(reportsTotal: false)
        let events = await known.run().events
        #expect(events.compactMap(\.started).first?.totalMs == 70_000)
        #expect(known.checkpoints.saved.map(\.totalMs) == [70_000, 70_000, 70_000])

        let unknown = try await Harness(duration: 0, reportsTotal: false)
        #expect(await unknown.run().events.compactMap(\.started).first?.totalMs == 0)
        #expect(unknown.checkpoints.saved.first?.totalMs == 0)
        #expect(unknown.checkpoints.saved.last?.totalMs == 70_000, "the complete words give the total")

        // The transcriber's duration wins over the note's.
        let decoded = try await Harness(duration: 65)
        _ = await decoded.run()
        #expect(decoded.checkpoints.saved.first?.totalMs == 70_000)
    }

    // ports: TranscriptionJobTest#aStopBeforeTheFirstWindowIsDoneLeavesNoCheckpoint
    @Test func aStopBeforeTheFirstResultLeavesNoCheckpoint() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        h.transcriber.beforeSegment = { index in if index == 0 { stop.stop(.pause(.user)) } }
        h.transcriber.firstSegmentDelay = .milliseconds(300)
        let (outcome, events) = await h.run(stop: stop)
        #expect(outcome == .paused(.user))
        #expect(h.transcriber.starts == [0])
        #expect(h.checkpoints.saved.isEmpty)
        #expect(!h.files.exists(h.noteID))
        #expect(events.contains(.stopping))
    }

    @Test func aStopAskedBeforeTheRunStartsNothing() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        stop.stop(.pause(.user))
        #expect(await h.run(stop: stop).outcome == .paused(.user))
        #expect(h.transcriber.starts.isEmpty)
    }

    // ports: TranscriptionJobTest#aWorkFileWriteFailureIsASaveFailureNotAnOpenOne
    @Test func aCheckpointWriteFailureIsASaveFailure() async throws {
        let h = try await Harness()
        h.checkpoints.failsSaving = true
        #expect(await h.run().outcome == .failed(.save))
    }

    // ports: TranscriptionJobTest#stopAtAWindowThenResumeEqualsAnUninterruptedRun
    @Test func stopAtAResultThenResumeEqualsAnUninterruptedRun() async throws {
        let whole = try await Harness()
        #expect(await whole.run().outcome == .done)

        let stopped = try await Harness()
        let stop = StopSignal()
        stopped.transcriber.beforeSegment = { index in if index == 7 { stop.stop(.pause(.user)) } }
        let (outcome, events) = await stopped.run(stop: stop)
        #expect(outcome == .paused(.user))
        #expect(events.contains(.stopping))
        // The stop is honoured at the result it arrived in: 35–40 s is kept.
        let checkpoint = try #require(stopped.checkpoints.saved.last)
        #expect(checkpoint.doneMs == 40_000)
        #expect(checkpoint.wordsComplete == false)
        #expect(await stopped.note()?.transcript.isEmpty == true)

        stopped.transcriber.beforeSegment = { _ in }
        let (resumedOutcome, resumedEvents) = await stopped.run()
        #expect(resumedOutcome == .done)
        // The tracker starts the resumed draft from the checkpoint's words and elapsed time.
        let restored = try #require(resumedEvents.compactMap(\.started).first?.restored)
        #expect(restored.words == checkpoint.draftWords)
        #expect(restored.elapsedMs == checkpoint.elapsedMs)
        #expect(restored.doneMs == checkpoint.doneMs)
        #expect(stopped.transcriber.starts == [0, 39])

        let expected = try #require(await whole.note()), actual = try #require(await stopped.note())
        #expect(actual.transcript == expected.transcript)
        #expect(whole.applied.count == 1 && stopped.applied.count == 1)
        #expect(expected.provenance?.resumedFromMs == 0)
        #expect(actual.provenance?.resumedFromMs == 40_000)
        var same = actual.provenance
        same?.resumedFromMs = 0; same?.inferenceMs = expected.provenance?.inferenceMs ?? 0
        #expect(same == expected.provenance)
    }

    // ports: TranscriptionJobTest#cancelInsideASlowNativeCallKeepsThePreviousCheckpointAndReleasesHandles
    @Test func aCancelEndsCancelledAndLeavesTheEarlierCheckpointToTheCoordinator() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        h.transcriber.beforeSegment = { index in if index == 9 { stop.stop(.cancel) } }
        #expect(await h.run(stop: stop).outcome == .cancelled)
        #expect(h.checkpoints.saved.map(\.doneMs) == [30_000])
        #expect(try h.files.load(h.noteID)?.doneMs == 30_000)
    }

    @Test func cancellingTheRunsTaskCancelsTheJob() async throws {
        let h = try await Harness()
        h.transcriber.hangs = true
        let task = Task { await h.run().outcome }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    // ports: TranscriptionJobTest#withoutConsentNothingIsInstalledAndNothingIsDecoded
    @Test func withoutConsentNothingIsDownloadedAndNothingIsDecoded() async throws {
        let h = try await Harness(speechStatus: .notDownloaded, settings: JobSettings(
            allowSpeechDownload: false, identifySpeakers: true, allowSpeakerDownload: false))
        let (outcome, events) = await h.run()
        #expect(outcome == .needsConsent(missingBytes: 0))
        #expect(h.transcriber.starts.isEmpty)
        #expect(h.checkpoints.saved.isEmpty)
        #expect(!events.contains { if case .downloading = $0 { true } else { false } })
    }

    @Test func anUnsupportedLanguageFailsBeforeAnyWork() async throws {
        let h = try await Harness(speechStatus: .unsupported)
        #expect(await h.run().outcome == .failed(.unsupportedLanguage))
        #expect(h.transcriber.starts.isEmpty)
    }

    // ports: TranscriptionJobTest#aStopDuringTheDownloadStopsWaitingAndPauses
    @Test func aStopDuringTheDownloadStopsWaitingAndPauses() async throws {
        let h = try await Harness(speechStatus: .notDownloaded)
        h.transcriber.downloadsFirst = true
        h.transcriber.hangs = true
        let stop = StopSignal()
        let running = Task { await h.run(stop: stop) }
        try await Task.sleep(for: .milliseconds(150))
        stop.stop(.pause(.system))
        let (outcome, events) = await running.value
        #expect(outcome == .paused(.system))
        #expect(events.contains { if case .downloading = $0 { true } else { false } })
        #expect(h.checkpoints.saved.isEmpty)
    }

    // ports: TranscriptionJobTest#audioLongerThanTheLimitFailsBeforeAnyWork
    @Test func audioLongerThanTheLimitFailsBeforeAnyWork() async throws {
        let h = try await Harness(speechStatus: .notDownloaded, limits: .init(maxDurationMs: 60_000))
        #expect(await h.run().outcome == .failed(.long))
        #expect(h.transcriber.starts.isEmpty, "nothing is decoded")
        #expect(h.checkpoints.saved.isEmpty)
    }

    // ports: TranscriptionJobTest#aContainerDurationOverTheLimitFailsAtTheFirstBlock
    @Test func aFileDurationOverTheLimitFailsAtTheFirstResult() async throws {
        let h = try await Harness(duration: 0, limits: .init(maxDurationMs: 60_000))
        #expect(await h.run().outcome == .failed(.long))
        #expect(h.transcriber.emitted <= 1, "no more results are taken")
        #expect(h.checkpoints.saved.isEmpty)
    }

    // ports: TranscriptionJobTest#aLongRecordingIsNotRefusedForItsDuration
    @Test func aLongRecordingIsNotRefusedForItsDuration() async throws {
        let h = try await Harness(duration: 30 * 3600)
        #expect(await h.run().outcome == .done)
    }

    @Test func audioUnder200MillisecondsIsTooShort() async throws {
        let before = try await Harness(duration: 0.1)
        #expect(await before.run().outcome == .failed(.short))
        #expect(before.transcriber.starts.isEmpty)

        let after = try await Harness(duration: 0, script: [])
        after.transcriber.total = 0.15
        #expect(await after.run().outcome == .failed(.short))
    }

    // ports: TranscriptionJobTest#wordsThatOutgrowTheWordBodyFailAtTheWindowThatPassesTheLimit
    @Test func wordsThatOutgrowTheWordBodyFailAtTheCheckpointThatPassesTheLimit() async throws {
        let h = try await Harness(limits: .init(maxBodyBytes: 4_000))
        let (outcome, events) = await h.run()
        #expect(outcome == .failed(.long))
        #expect(h.checkpoints.saved.map(\.doneMs) == [30_000], "the checkpoint before the limit stays")
        #expect(!events.contains { if case .namingClosed = $0 { true } else { false } })

        // Transcribe again resumes from that checkpoint and fails again at the same point, not after a full run.
        let (again, _) = await h.run()
        #expect(again == .failed(.long))
        #expect(h.transcriber.starts == [0, 29])
    }

    // ports: TranscriptionJobTest#aCheckpointThatNoLongerMatchesFailsTheJob
    @Test func aCheckpointThatNoLongerMatchesFailsTheJob() async throws {
        let h = try await Harness()
        try h.files.save(CheckpointState(source: "audio.m4a", signature: "1:2", language: "it-IT", segments: [],
                                         doneMs: 0, totalMs: 70_000, elapsedMs: 0), for: h.noteID)
        #expect(await h.run().outcome == .failed(.checkpointMismatch))
        #expect(h.transcriber.starts.isEmpty)

        let damaged = try await Harness()
        let folder = damaged.files.directory(for: damaged.noteID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent(CheckpointFiles.filename))
        #expect(await damaged.run().outcome == .failed(.checkpointMismatch))
    }

    @Test func aChangedLanguageNoLongerMatches() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        h.transcriber.beforeSegment = { index in if index == 7 { stop.stop(.pause(.user)) } }
        _ = await h.run(stop: stop)
        #expect(await h.run(language: "en-US").outcome == .failed(.checkpointMismatch))
    }

    // ports: TranscriptionJobTest#aDiarizerFailureDegradesToOneVoice
    @Test func aSpeakerFailureDegradesToOneVoice() async throws {
        let h = try await Harness(analyzer: FailingAnalyzer())
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(events.contains(.speakersUnavailable))
        #expect(!events.contains { $0.stage == .matching })
        let note = try #require(await h.note())
        #expect(note.speakerAnalysisFailure == .speakers)
        #expect(note.transcript.flatMap(\.words).count == 70)
        #expect(note.provenance?.speakerDiarization == nil)
        #expect(h.applied.isEmpty)
    }

    @Test func aFailedSpeakerSaveAlsoDegradesToOneVoice() async throws {
        let h = try await Harness()
        h.host.failsApplying = true
        #expect(await h.run().outcome == .done)
        #expect(await h.note()?.speakerAnalysisFailure == .speakers)
    }

    // ports: TranscriptionJobTest#provenanceEqualsThe010Record (adapted: the iOS record)
    @Test func provenanceCarriesTheEngineAndTheSpeakerRecord() async throws {
        let analysis = SpeakerAnalysis(
            turns: [.init(speakerID: "a", start: 0, end: 30), .init(speakerID: "b", start: 30, end: 70),
                    .init(speakerID: "a", start: 70, end: 71)],
            prints: [SpeakerPrint(speakerID: "a", model: "pyannote-community-1:abc123", vector: [1, 0], speechSeconds: 30)])
        let h = try await Harness(analyzer: FakeAnalyzer(analysis: analysis))
        #expect(await h.run().outcome == .done)
        let provenance = try #require(await h.note()?.provenance)
        let record = provenance.record()
        #expect(record.keys == ["engine", "language", "x-inferenceMs", "x-resumedFromMs", "x-speakerDiarization"])
        #expect(record["engine"]?.string == "apple-speechtranscriber")
        #expect(record["language"]?.string == "it-IT")
        let diarization = try #require(record["x-speakerDiarization"]?.object)
        #expect(diarization.keys == ["backend", "model", "sha", "turnCount", "speakerCount"])
        #expect(diarization["backend"]?.string == "fluidaudio")
        #expect(diarization["model"]?.string == "pyannote-community-1")
        #expect(diarization["sha"]?.string == "abc123")
        #expect(provenance.speakerDiarization?.turnCount == 3)
        #expect(provenance.speakerDiarization?.speakerCount == 2)
        #expect(h.applied.map(\.generation) == [7])
    }

    @Test func withoutTheSpeakerStepTheWordsAreSavedAlone() async throws {
        let h = try await Harness(settings: JobSettings(allowSpeechDownload: true, identifySpeakers: false,
                                                       allowSpeakerDownload: true))
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(events.contains(.namingClosed(matching: false)))
        #expect(!events.contains { $0.stage == .speakers })
        #expect(events.compactMap(\.started).first?.speakers == false)
        #expect(h.applied.isEmpty)
    }

    @Test func aSpeakersOnlyJobLeavesTheWordsAlone() async throws {
        let h = try await Harness()
        let words = [TranscriptSegment(text: "Kept", start: 0, end: 1)]
        _ = try await h.notes.mutate(h.noteID) { $0.transcript = words }
        let (outcome, events) = await h.run(kind: .speakersOnly)
        #expect(outcome == .done)
        #expect(h.transcriber.starts.isEmpty)
        #expect(await h.note()?.transcript == words)
        #expect(h.applied.count == 1)
        #expect(events.contains { $0.stage == .speakers })
    }

    @Test func aStopInTheSpeakerStepKeepsTheWordsAndResumesWithTheSpeakers() async throws {
        let analyzer = FakeAnalyzer(suspends: true)
        let h = try await Harness(analyzer: analyzer)
        let stop = StopSignal()
        let running = Task { await h.run(stop: stop) }
        while analyzer.analyzeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        stop.stop(.pause(.user))
        // The analysis ends at its next check once the stop cancelled it.
        try await Task.sleep(for: .milliseconds(100))
        analyzer.resume()
        let (outcome, _) = await running.value
        #expect(outcome == .paused(.user))
        #expect(try h.files.load(h.noteID)?.wordsComplete == true)
        #expect(await h.note()?.transcript.flatMap(\.words).count == 70, "the words are in the note")

        let (resumed, _) = await h.run()
        #expect(resumed == .done)
        #expect(h.transcriber.starts == [0], "the words are not transcribed again")
        #expect(h.applied.count == 1)
        #expect(!h.files.exists(h.noteID))
    }

    @Test func volatileResultsReachTheDraft() async throws {
        let h = try await Harness()
        h.transcriber.volatileBeforeEachSegment = true
        let events = await h.run().events
        let drafts = events.compactMap { if case .draft(let words, let tentative) = $0 { (words, tentative) } else { nil } }
        #expect(!drafts.isEmpty)
        #expect(drafts.allSatisfy { $0.0.last?.text.hasPrefix("maybe") == true })
    }

    // ports: TranscriptionJobTest#theTrackerTurnsTheJobEventsIntoMonotonicProgress
    @Test func theTrackerTurnsTheJobEventsIntoMonotonicProgress() async throws {
        let h = try await Harness()
        let events = await h.run().events
        var tracker = ProgressTracker()
        var now: Int64 = 0
        var steps: [JobStep] = [], percents: [Int] = []
        for event in events {
            now += 500
            tracker.apply(event, at: now)
            tracker.tick(at: now)
            if case .transcribing(let progress, _) = tracker.phase {
                steps.append(progress.step)
                if let percent = progress.percent { percents.append(percent) }
            }
        }
        #expect(steps == steps.sorted())
        #expect(percents == percents.sorted())
        #expect(percents.last == 100)
        #expect(Set(steps) == Set(JobStep.allCases))
    }
}

// MARK: - Harness

private struct Harness {
    let root: URL
    let notes: NoteStore
    let noteID = UUID()
    let audioURL: URL
    let files: CheckpointFiles
    let checkpoints: RecordingCheckpoints
    let transcriber: ScriptedTranscriber
    let analyzer: any SpeakerAnalyzing
    let host: FakeHost
    let limits: TranscriptionJob.Limits

    var applied: [(noteID: UUID, generation: Int)] { host.applied }

    init(duration: TimeInterval = 70, reportsTotal: Bool = true, script: [TranscriptSegment] = ScriptedTranscriber.seventySeconds,
         speechStatus: ModelPartStatus = .ready, analyzer: any SpeakerAnalyzing = FakeAnalyzer(),
         settings: JobSettings = JobSettings(allowSpeechDownload: true, identifySpeakers: true,
                                             allowSpeakerDownload: true, voicesGeneration: 7),
         limits: TranscriptionJob.Limits = .init()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        notes = try NoteStore(root: root)
        var note = Note(id: noteID, title: "Riunione", audioFilename: "audio.m4a")
        note.duration = duration
        note.language = "it-IT"
        try await notes.save(note)
        audioURL = notes.audioURL(for: note)
        try Data(count: 4096).write(to: audioURL)
        files = CheckpointFiles(root: root)
        checkpoints = RecordingCheckpoints(files)
        transcriber = ScriptedTranscriber(script: script, total: reportsTotal ? 70 : 0, status: speechStatus)
        self.analyzer = analyzer
        host = FakeHost(settings)
        self.limits = limits
    }

    func note() async -> Note? { await notes.note(noteID) }

    func run(kind: JobKind = .transcribe, language: String = "it-IT", stop: StopSignal = StopSignal(),
             observe: @escaping @Sendable (JobEvent) -> Void = { _ in }) async -> (outcome: JobOutcome, events: [JobEvent]) {
        let uptime = FakeUptime()
        let job = TranscriptionJob(notes: notes, transcriber: transcriber, analyzer: analyzer, checkpoints: checkpoints,
                                   host: host, clock: FakeClock(), limits: limits, uptimeMs: { uptime.next() })
        let record = Job(noteID: noteID, seq: 1, kind: kind, state: .running, language: language, enqueuedAt: Date())
        let events = Mutex<[JobEvent]>([])
        let outcome = await job.run(record, stop: stop) { event in
            observe(event)
            events.withLock { $0.append(event) }
        }
        return (outcome, events.withLock { $0 })
    }
}

/// Monotonic time that moves 10 s at every read, so every due checkpoint is also due in time.
private final class FakeUptime: Sendable {
    private let now = Mutex<Int64>(0)
    func next() -> Int64 { now.withLock { $0 += 10_000; return $0 } }
}

/// Emits `script` from the request's start offset: each result whose end is after it, then its progress.
private final class ScriptedTranscriber: Transcribing, @unchecked Sendable {
    /// 14 results of 5 s, one word a second ("w0" at 0–0.8 s).
    static let seventySeconds: [TranscriptSegment] = (0..<14).map { index in
        let words = (0..<5).map { k in
            let second = index * 5 + k
            return TimedWord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 1000 + second))!,
                             text: (k == 0 ? "" : " ") + "w\(second)", start: Double(second), end: Double(second) + 0.8)
        }
        return TranscriptSegment(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                                 text: words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
                                 start: Double(index * 5), end: Double(index * 5 + 5), words: words)
    }

    private let lock = NSLock()
    private let script: [TranscriptSegment]
    private let status: ModelPartStatus
    private var _starts: [TimeInterval] = []
    private var _emitted = 0
    var total: TimeInterval
    var beforeSegment: @Sendable (Int) -> Void = { _ in }
    var firstSegmentDelay: Duration?
    var hangs = false
    var downloadsFirst = false
    var volatileBeforeEachSegment = false

    init(script: [TranscriptSegment], total: TimeInterval, status: ModelPartStatus) {
        self.script = script; self.total = total; self.status = status
    }

    var starts: [TimeInterval] { lock.withLock { _starts } }
    var emitted: Int { lock.withLock { _emitted } }

    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        lock.withLock { _starts.append(request.startOffset) }
        if downloadsFirst { events(.preparingModel(0.25)) }
        if hangs { while true { try await Task.sleep(for: .seconds(60)) } }
        events(.progress(done: request.startOffset, total: total))
        var out: [TranscriptSegment] = []
        for (index, segment) in script.enumerated() where segment.end > request.startOffset {
            if index == 0, let firstSegmentDelay { beforeSegment(index); try await Task.sleep(for: firstSegmentDelay) }
            else { beforeSegment(index) }
            try Task.checkCancellation()
            if volatileBeforeEachSegment {
                events(.volatile(TranscriptSegment(text: "maybe", start: segment.start, end: segment.end,
                                                   words: [TimedWord(text: "maybe", start: segment.start, end: segment.end)])))
            }
            lock.withLock { _emitted += 1 }
            events(.finalized(segment))
            events(.progress(done: segment.end, total: total))
            out.append(segment)
        }
        return TranscriptionResult(segments: out)
    }

    func assetStatus(locale: Locale) async -> ModelPartStatus { status }
}

/// The real files, recording each checkpoint saved.
private final class RecordingCheckpoints: CheckpointStoring, @unchecked Sendable {
    private let files: CheckpointFiles
    private let lock = NSLock()
    private var _saved: [CheckpointState] = []
    var failsSaving = false

    init(_ files: CheckpointFiles) { self.files = files }

    var saved: [CheckpointState] { lock.withLock { _saved } }

    func load(_ noteID: UUID) throws -> CheckpointState? { try files.load(noteID) }
    func save(_ state: CheckpointState, for noteID: UUID) throws {
        if lock.withLock({ failsSaving }) { throw CocoaError(.fileWriteOutOfSpace) }
        try files.save(state, for: noteID)
        lock.withLock { _saved.append(state) }
    }
    func discard(_ noteID: UUID) throws { try files.discard(noteID) }
    func exists(_ noteID: UUID) -> Bool { files.exists(noteID) }
}

private final class FakeHost: TranscriptionJobHost, @unchecked Sendable {
    private let lock = NSLock()
    private let settings: JobSettings
    private var _applied: [(noteID: UUID, generation: Int)] = []
    var failsApplying = false

    init(_ settings: JobSettings) { self.settings = settings }

    var applied: [(noteID: UUID, generation: Int)] { lock.withLock { _applied } }

    func jobSettings() async -> JobSettings { settings }
    func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
        if failsApplying { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { _applied.append((noteID, generation)) }
    }
}

private struct FailingAnalyzer: SpeakerAnalyzing {
    struct Failure: Error {}
    func analyze(url: URL, allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        throw Failure()
    }
    var modelIdentity: String? { get async { "m:1" } }
    func modelStatus() async -> ModelPartStatus { .ready }
}

private extension JobEvent {
    var checkpointed: Int64? { if case .checkpointed(let doneMs) = self { doneMs } else { nil } }
    var started: JobStart? { if case .started(let start) = self { start } else { nil } }
    var isStarted: Bool { started != nil }
    var stage: TranscriptionStage? { if case .stageChanged(let stage, _, _) = self { stage } else { nil } }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
