import CassiniCore
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// A Parakeet job that tells speakers apart as it decodes (Android's `TranscriptionJob.onWindow`): the scripted
/// recognizer of `TranscriptionJobParakeetTests` (one word a second over 70 s, 28 s windows) and a scripted diarizer
/// that hears speaker A (slot 0) until 35 s and B (slot 1) after it, through the real `WindowSpeakers`,
/// `Diarization.assign`, `TurnHistory` and voice-clip cache.
@Suite struct TranscriptionJobStreamingTests {
    typealias Harness = TranscriptionJobTests.Harness

    /// A until 35 s, B after it, on the window's clock.
    static let twoSpeakers: FakeSpeakerEngines.Turns = { startMs, durationMs in
        var turns: [DiarizerTurn] = []
        let change: Int64 = 35_000 - startMs
        if change > 0 { turns.append(DiarizerTurn(0, min(change, durationMs), 0)) }
        if change < durationMs { turns.append(DiarizerTurn(max(change, 0), durationMs, 1)) }
        return turns
    }

    private func harness(engines: FakeSpeakerEngines = FakeSpeakerEngines(turns: twoSpeakers), printsReady: Bool = true,
                         transcriber: WindowedTranscriber = WindowedTranscriber()) async throws -> (Harness, FakeSpeakerEngines) {
        (try await Harness(analyzer: FakeAnalyzer(engines: engines, printsReady: printsReady), engine: transcriber), engines)
    }

    private func speakers(_ words: [DraftWord]) -> [String] { words.map(\.speaker) }

    // ports: TranscriptionJobTest#decodesIn28SecondWindowsAndSavesOneCheckpointPerWindow (with the diarizer)
    @Test func eachWindowsWordsGetTheirSpeakersAsTheyAreDecoded() async throws {
        let (h, engines) = try await harness()
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        // The draft shows the speakers from the first window on.
        let firstDraft = try #require(events.compactMap { event -> [DraftWord]? in
            if case .windowDone(_, _, let words) = event, !words.isEmpty { words } else { nil }
        }.first)
        let prefix = try #require(firstDraft.first?.speaker.dropLast())
        #expect(Set(speakers(firstDraft)) == ["\(prefix)1"], "A alone in the first 28 s")
        // One diarizer for the run, never restored.
        #expect(engines.opened.count == 1 && engines.opened[0] == nil)
        // The note: A's words, then B's, with the run's ids.
        let note = try #require(await h.note())
        let words = note.transcript.flatMap(\.draftWords)
        #expect(words.map(\.text) == (0..<70).map { "w\($0)" })
        #expect(speakers(Array(words.prefix(35))) == Array(repeating: "\(prefix)1", count: 35))
        #expect(speakers(Array(words.suffix(35))) == Array(repeating: "\(prefix)2", count: 35))
        // What the note was given: the streamed words, the turns on the recording clock, a CAM++ print per speaker.
        let analysis = try #require(h.host.analyses.first)
        #expect(analysis.transcript?.flatMap(\.draftWords) == words)
        #expect(analysis.turns.map(\.speakerID).uniqued() == ["\(prefix)1", "\(prefix)2"])
        #expect(analysis.turns.first?.start == 0 && analysis.turns.last?.end == 70)
        #expect(analysis.prints.map(\.speakerID) == ["\(prefix)1", "\(prefix)2"])
        #expect(analysis.prints.allSatisfy { $0.model == VoiceprintModel.sha256 && $0.vector.count == 512 })
        #expect(analysis.prints.allSatisfy { $0.speechSeconds >= Voiceprints.minSecondsPerSpeaker && $0.speechSeconds <= 45 })
        #expect(analysis.streaming && analysis.printsReady)
        #expect(analysis.elapsedMs == 15, "three windows of the diarizer's own time")
        // Matching follows the words; the speaker step of the Apple path does not run.
        #expect(events.contains { $0.stage == .matching })
        #expect(!events.contains { $0.stage == .speakers })
        #expect(events.compactMap(\.started).first?.speakers == true)
        // The record: Android's Sortformer record with its windows, and the identification.
        let record = try #require(h.provenance(of: note))
        #expect(record.speakerDiarization?.incremental == TranscriptProvenance.SpeakerDiarization.incrementalWindows)
        #expect(record.speakerDiarization?.speakerCount == 2)
        #expect(record.speakerIdentification?.speakersWithPrints == 2)
        #expect(!h.files.exists(h.noteID), "the work, clips too, is removed once the note is saved")
    }

    // ports: TranscriptionJobTest#checkpointsOnlyCountWhatWasFsynced (the clips)
    @Test func eachCheckpointCarriesTheSpeakersAndTheClipsItCounts() async throws {
        let (h, _) = try await harness()
        let stop = StopSignal()
        let transcriber = try #require(h.engine as? WindowedTranscriber)
        transcriber.beforeWindow = { index in if index == 1 { stop.stop(.pause(.user)) } }
        #expect(await h.run(stop: stop).outcome == .paused(.user))
        let checkpoint = try #require(h.checkpoints.saved.last)
        let speakers = try #require(checkpoint.speakers)
        #expect(checkpoint.doneMs == 54_000)
        #expect(speakers.diarizer?.cache == [2], "the diarizer saw two windows")
        #expect(speakers.diarizer?.turns.map(\.speaker).uniqued() == [0, 1], "A, then B from 35 s")
        #expect(Set(speakers.voiceClips.keys) == ["\(speakers.prefix)1", "\(speakers.prefix)2"])
        let clips = try #require(h.files.clipsURL(for: h.noteID))
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: clips.path)[.size] as? Int)
        #expect(bytes >= speakers.clipSamples * 4, "the clips the checkpoint counts are on disk")
        #expect(speakers.voiceClips.values.joined().allSatisfy { $0.endSample <= speakers.clipSamples })
        // The draft words of the checkpoint carry the speakers too.
        #expect(Set(checkpoint.draftWords.map(\.speaker)) == ["\(speakers.prefix)1", "\(speakers.prefix)2"])
    }

    // ports: TranscriptionJobTest#stopAtAWindowThenResumeEqualsAnUninterruptedRun (with the diarizer)
    @Test func stopAtAWindowThenResumeEqualsAnUninterruptedRun() async throws {
        let (whole, _) = try await harness()
        #expect(await whole.run().outcome == .done)
        let expected = try #require(whole.host.analyses.first)

        let (stopped, engines) = try await harness()
        let transcriber = try #require(stopped.engine as? WindowedTranscriber)
        let stop = StopSignal()
        transcriber.beforeWindow = { index in if index == 1 { stop.stop(.pause(.user)) } }
        #expect(await stopped.run(stop: stop).outcome == .paused(.user))
        let saved = try #require(stopped.checkpoints.saved.last?.speakers)
        transcriber.beforeWindow = { _ in }
        #expect(await stopped.run().outcome == .done)
        // The second run's diarizer goes on from the saved state, with the run's own prefix.
        #expect(engines.opened.count == 2 && engines.opened[1] == saved.diarizer)
        let actual = try #require(stopped.host.analyses.first)
        let prefix = { (id: String) in String(id.split(separator: "_").last ?? "") }
        #expect(actual.turns.map { [$0.start, $0.end] } == expected.turns.map { [$0.start, $0.end] })
        #expect(actual.turns.map { prefix($0.speakerID) } == expected.turns.map { prefix($0.speakerID) })
        #expect(actual.turns.allSatisfy { $0.speakerID.hasPrefix(saved.prefix) })
        #expect(actual.transcript?.flatMap(\.draftWords).map { prefix($0.speaker) }
            == expected.transcript?.flatMap(\.draftWords).map { prefix($0.speaker) })
        #expect(actual.prints.map(\.speechSeconds) == expected.prints.map(\.speechSeconds),
                "the clips of the first run are kept, the second run adds its own")
    }

    /// A stop during the voiceprints keeps the complete checkpoint; the resumed run makes the prints from the clips on
    /// disk without decoding again.
    @Test func aStopAfterTheWordsResumesWithTheStreamedSpeakers() async throws {
        let (h, engines) = try await harness()
        let stop = StopSignal()
        let (outcome, _) = await h.run(stop: stop, observe: { event in
            if case .namingClosed = event { stop.stop(.pause(.user)) }
        })
        #expect(outcome == .paused(.user))
        #expect(try h.files.load(h.noteID)?.wordsComplete == true)
        #expect(h.host.analyses.isEmpty)
        #expect(await h.run().outcome == .done)
        let transcriber = try #require(h.engine as? WindowedTranscriber)
        #expect(transcriber.requests.count == 1, "the words are not decoded again")
        #expect(engines.opened.count == 1, "nor diarized again")
        let analysis = try #require(h.host.analyses.first)
        #expect(analysis.prints.count == 2)
        #expect(Set(analysis.transcript?.flatMap(\.draftWords).map(\.speaker) ?? []).count == 2)
    }

    // ports: TranscriptionJobTest#aDiarizerFailureDegradesToOneVoice
    @Test func aDiarizerFailureDegradesToOneVoice() async throws {
        let (h, _) = try await harness(engines: FakeSpeakerEngines(failAt: 26_000, turns: Self.twoSpeakers))
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(events.filter { $0 == .speakersUnavailable }.count == 1)
        // The first window keeps its speakers; every later word is one voice (`<prefix>1`), as on Android.
        let analysis = try #require(h.host.analyses.first)
        let transcript = try #require(analysis.transcript)
        let words = transcript.flatMap(\.draftWords)
        let first = try #require(words.first)
        let prefix = String(first.speaker.dropLast())
        #expect(Set(words.map(\.speaker)) == ["\(prefix)1"])
        #expect(analysis.turns.allSatisfy { $0.end <= 28 }, "the turns of the window before the failure")
        #expect(h.provenance(of: await h.note())?.speakerDiarization != nil, "the earlier windows were told apart")
    }

    // ports: TranscriptionJobTest#aDiarizerFailureAtTheFirstWindowSealsOneVoiceWithoutTheRecord
    @Test func aDiarizerFailureAtTheFirstWindowLeavesOneVoiceWithoutTheRecord() async throws {
        let (h, _) = try await harness(engines: FakeSpeakerEngines(failAt: 0, turns: Self.twoSpeakers))
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(events.contains(.speakersUnavailable))
        #expect(h.applied.isEmpty)
        let note = try #require(await h.note())
        #expect(note.speakerAnalysisFailure == .speakers)
        let id = TranscriptionJobTests.OneVoice.expectOneVoice(note)
        let prefix = try #require(h.checkpoints.saved.last?.speakers?.prefix)
        #expect(id == prefix + "1", "the one voice is the run's own, as its words were (D59)")
        #expect(h.provenance(of: note)?.speakerDiarization == nil)
    }

    /// D59: a run resumed after its speakers failed keeps the prefix its checkpoint saved, so the one voice is the id
    /// its words got before the stop, not a new one.
    @Test func aResumedRunKeepsItsOwnOneVoice() async throws {
        let (h, _) = try await harness(engines: FakeSpeakerEngines(failAt: 0, turns: Self.twoSpeakers))
        let transcriber = try #require(h.engine as? WindowedTranscriber)
        let stop = StopSignal()
        transcriber.beforeWindow = { index in if index == 1 { stop.stop(.pause(.user)) } }
        #expect(await h.run(stop: stop).outcome == .paused(.user))
        let saved = try #require(h.checkpoints.saved.last?.speakers)
        #expect(saved.failed)
        transcriber.beforeWindow = { _ in }
        #expect(await h.run().outcome == .done)
        let note = try #require(await h.note())
        #expect(TranscriptionJobTests.OneVoice.expectOneVoice(note) == saved.prefix + "1")
        #expect(note.speakerAnalysisFailure == .speakers)
    }

    /// Without CAM++ the speakers are told apart and no clip is kept: no prints, no identification.
    @Test func withoutTheVoiceprintModelNoClipIsKept() async throws {
        let (h, engines) = try await harness(printsReady: false)
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(events.compactMap(\.started).first?.prints == false)
        #expect(events.contains(.namingClosed(matching: false)))
        #expect(engines.printRequests.isEmpty)
        let analysis = try #require(h.host.analyses.first)
        #expect(analysis.prints.isEmpty && !analysis.printsReady)
        #expect(h.provenance(of: await h.note())?.speakerIdentification == nil)
        #expect(h.checkpoints.saved.allSatisfy { $0.speakers?.clipSamples == 0 && $0.speakers?.voiceClips.isEmpty == true })
    }

    /// A Parakeet checkpoint whose speakers were not streamed (speakers were off when it was written) gets them from the
    /// whole file after the words, so its early words are not left without one.
    @Test func aCheckpointWithoutStreamedSpeakersGetsThemAfterTheWords() async throws {
        let analyzer = FakeAnalyzer(analysis: SpeakerAnalysis(turns: [.init(speakerID: "1", start: 0, end: 70)], prints: []),
                                    engines: FakeSpeakerEngines(turns: Self.twoSpeakers))
        let transcriber = WindowedTranscriber()
        let h = try await Harness(analyzer: analyzer, engine: transcriber)
        let state = CheckpointState(source: "audio.m4a", signature: CheckpointState.signature(of: h.audioURL),
                                    model: ModelCatalog.parakeetRevision,
                                    segments: TranscriptSegment.segments(of: (0..<28).map {
                                        Word("", Int64($0) * 1000, Int64($0) * 1000 + 800, "w\($0)")
                                    }),
                                    doneMs: 28_000, totalMs: 70_000, elapsedMs: 1_000,
                                    recognition: RecognitionCheckpoint(start: 416_000, end: 448_000, position: 448_000))
        try h.files.save(state, for: h.noteID)
        #expect(await h.run().outcome == .done)
        #expect(transcriber.requests.first?.speakers == nil)
        #expect(analyzer.analyzeCount == 1)
        #expect(analyzer.analyzedWords.first?.map(\.text) == (0..<70).map { "w\($0)" })
    }

    // ports: TranscriptionJobTest#missingModelsAreInstalledWithConsentAndADownloadFailureFailsTheJob (the speaker
    // parts, which are best effort)
    @Test func missingSpeakerModelsAreInstalledBeforeTheDecodeAndAFailureLeavesOneVoice() async throws {
        let installing = InstallingAnalyzer(engines: FakeSpeakerEngines(turns: Self.twoSpeakers), failure: nil)
        let h = try await Harness(analyzer: installing, engine: WindowedTranscriber())
        let (outcome, events) = await h.run()
        #expect(outcome == .done)
        #expect(installing.installs == 1)
        let downloads = events.firstIndex { if case .downloading = $0 { true } else { false } }
        let started = events.firstIndex { $0.isStarted }
        #expect(downloads != nil && started != nil && downloads! < started!, "installed before the decode")
        #expect(h.host.analyses.count == 1)

        let failing = InstallingAnalyzer(engines: FakeSpeakerEngines(turns: Self.twoSpeakers),
                                         failure: .download(.noConnection, requiredFreeBytes: 0))
        let f = try await Harness(analyzer: failing, engine: WindowedTranscriber())
        let (failed, failedEvents) = await f.run()
        #expect(failed == .done, "the words do not need the speaker models")
        #expect(failedEvents.compactMap(\.started).first?.speakers == false)
        #expect(f.host.analyses.isEmpty)
        #expect(await f.note()?.speakerAnalysisFailure == .speakers)
    }

    // ports: NativeBudgetTest (the job): a job whose native models would load while another holds the budget waits,
    // shown as "Finishing the previous note…"; a stop ends the wait without a decode.
    @Test func aJobWaitsForTheNativeBudgetAndAStopEndsTheWait() async throws {
        let (h, _) = try await harness()
        try await h.budget.acquire()
        let stop = StopSignal()
        let observed = Mutex<[JobEvent]>([])
        let running = Task { await h.run(stop: stop, observe: { event in observed.withLock { $0.append(event) } }) }
        while !observed.withLock({ $0.contains(.waitingForPrevious) }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!observed.withLock { $0.contains { $0.isStarted } }, "nothing loads before the budget is free")
        stop.stop(.pause(.user))
        let (outcome, events) = await running.value
        #expect(outcome == .paused(.user))
        #expect(!events.contains { $0.isStarted })
        #expect(h.checkpoints.saved.isEmpty)
        h.budget.release()
        #expect(!h.budget.isHeld)

        // Once the budget is free the job runs, and gives it back.
        try await h.budget.acquire()
        let waiting = Task { await h.run() }
        try await Task.sleep(for: .milliseconds(50))
        h.budget.release()
        #expect(await waiting.value.outcome == .done)
        #expect(!h.budget.isHeld)
    }
}

/// A speaker analyzer whose models are missing until `installModels` runs; then `engines` stream.
final class InstallingAnalyzer: SpeakerAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private let engines: FakeSpeakerEngines
    private let failure: SpeakerAnalysisError?
    private var installed = false
    private var count = 0

    init(engines: FakeSpeakerEngines, failure: SpeakerAnalysisError?) { self.engines = engines; self.failure = failure }

    var installs: Int { lock.withLock { count } }

    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        throw failure ?? .needsConsent
    }
    func streamingEngines() async -> (any SpeakerEngines)? { lock.withLock { installed } ? engines : nil }
    func printsReady() async -> Bool { lock.withLock { installed } }
    func modelStatus() async -> ModelPartStatus { lock.withLock { installed } ? .ready : .notDownloaded }
    func refreshModelStatus() async -> ModelPartStatus { await modelStatus() }
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        lock.withLock { count += 1 }
        progress(.downloading(0.5))
        if let failure { throw failure }
        lock.withLock { installed = true }
    }
    var modelInstallBytes: Int64 { 0 }
}
