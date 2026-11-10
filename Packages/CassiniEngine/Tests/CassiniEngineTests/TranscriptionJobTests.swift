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
        #expect(note.versions?.last?.kind == .transcription)
        #expect(h.provenance(of: note)?.engine == "apple-speechtranscriber")
        #expect(h.applied.count == 1)
        #expect(!h.files.exists(h.noteID), "the work is removed once the note is saved")
    }

    // ports: InstalledEnginesTest#aLongClipThatDoesNotFitTheHeapGivesTheLowMemoryHint
    @Test func theStartSaysWhetherTheRecordingFitsTheMemoryLeft() async throws {
        let h = try await Harness()
        // 70 s of 16 kHz float samples and 30 % headroom is about 5.8 MB.
        #expect(await h.run(availableMemory: 4 << 20).events.compactMap(\.started).first?.lowMemory == true)
        let roomy = try await Harness()
        #expect(await roomy.run(availableMemory: 64 << 20).events.compactMap(\.started).first?.lowMemory == false)
        let unknown = try await Harness()
        #expect(await unknown.run().events.compactMap(\.started).first?.lowMemory == false)
    }

    // ports: TranscriptionJobTest#checkpointsOnlyCountWhatWasFsynced
    @Test func checkpointsOnlyCountWhatIsOnDisk() async throws {
        let h = try await Harness()
        let files = h.files, noteID = h.noteID
        let mismatches = Mutex<[Int64]>([])
        let (outcome, _) = await h.run(observe: { event in
            guard case .checkpointed(let doneMs) = event else { return }
            let stored = try? files.load(noteID)
            if stored?.doneMs != doneMs { mismatches.withLock { $0.append(doneMs) } }
        })
        #expect(outcome == .done)
        #expect(mismatches.withLock { $0 }.isEmpty)
        let first = try #require(h.checkpoints.saved.first)
        #expect(first.source == "audio.m4a")
        #expect(first.signature == CheckpointState.signature(of: h.audioURL))
        #expect(first.model == CheckpointState.appleModel(language: "it-IT"))
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
        h.transcriber.beforeSegment = ScriptedTranscriber.stops(stop, at: 0)
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
        h.checkpoints.failsSaving = CocoaError(.fileWriteUnknown)
        #expect(await h.run().outcome == .failed(.save))

        // A full volume is SPACE, as Android's writeFailure() says.
        let full = try await Harness()
        full.checkpoints.failsSaving = CheckpointSpaceError()
        #expect(await full.run().outcome == .failed(.space))
        let outOfSpace = try await Harness()
        outOfSpace.checkpoints.failsSaving = CocoaError(.fileWriteOutOfSpace)
        #expect(await outOfSpace.run().outcome == .failed(.space))
    }

    // ports: TranscriptionJobTest#stopAtAWindowThenResumeEqualsAnUninterruptedRun
    @Test func stopAtAResultThenResumeEqualsAnUninterruptedRun() async throws {
        let whole = try await Harness()
        #expect(await whole.run().outcome == .done)

        let stopped = try await Harness()
        let stop = StopSignal()
        stopped.transcriber.afterSegment = ScriptedTranscriber.stops(stop, at: 7)
        let (outcome, events) = await stopped.run(stop: stop)
        #expect(outcome == .paused(.user))
        #expect(events.contains(.stopping))
        // The stop came once the result at 35–40 s was in: it is kept.
        let checkpoint = try #require(stopped.checkpoints.saved.last)
        #expect(checkpoint.doneMs == 40_000)
        #expect(checkpoint.wordsComplete == false)
        #expect(await stopped.note()?.transcript.isEmpty == true)

        stopped.transcriber.afterSegment = { _ in }
        let (resumedOutcome, resumedEvents) = await stopped.run()
        #expect(resumedOutcome == .done)
        // The tracker starts the resumed draft from the checkpoint's words and elapsed time.
        let restored = try #require(resumedEvents.compactMap(\.started).first?.restored)
        #expect(restored.words == checkpoint.draftWords)
        #expect(restored.elapsedMs == checkpoint.elapsedMs)
        #expect(restored.doneMs == checkpoint.doneMs)
        #expect(stopped.transcriber.starts == [0, 39])

        let expected = try #require(await whole.note()), actual = try #require(await stopped.note())
        // The speaker step gives the passages new ids; the words and their texts are the same.
        #expect(actual.transcript.map(\.text) == expected.transcript.map(\.text))
        #expect(actual.transcript.flatMap(\.words) == expected.transcript.flatMap(\.words))
        #expect(whole.applied.count == 1 && stopped.applied.count == 1)
        let wholeProvenance = whole.provenance(of: expected), resumedProvenance = stopped.provenance(of: actual)
        #expect(wholeProvenance?.resumedFromMs == 0)
        #expect(resumedProvenance?.resumedFromMs == 40_000)
        var same = resumedProvenance
        same?.resumedFromMs = 0; same?.inferenceMs = wholeProvenance?.inferenceMs ?? 0
        #expect(same == wholeProvenance)
    }

    /// A job without a language (a rebuilt queue's) resumes Apple Speech's saved progress in the language it began in,
    /// never in the note's: the checkpoint's.
    @Test func aJobWithoutALanguageResumesInTheCheckpointsLanguage() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        h.transcriber.afterSegment = ScriptedTranscriber.stops(stop, at: 7)
        #expect(await h.run(language: "fr-FR", stop: stop).outcome == .paused(.user))
        #expect(h.checkpoints.saved.last?.model == CheckpointState.appleModel(language: "fr-FR"))

        h.transcriber.afterSegment = { _ in }
        #expect(await h.run(language: "").outcome == .done)
        #expect(h.transcriber.starts == [0, 39], "it went on from the checkpoint")
        let note = try #require(await h.note())
        #expect(note.language == "fr-FR")
        #expect(h.provenance(of: note)?.language == "fr-FR")
    }

    // ports: TranscriptionJobTest#cancelInsideASlowNativeCallKeepsThePreviousCheckpointAndReleasesHandles
    @Test func aCancelEndsCancelledAndLeavesTheEarlierCheckpointToTheCoordinator() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        h.transcriber.afterSegment = ScriptedTranscriber.stops(stop, .cancel, at: 9)
        #expect(await h.run(stop: stop).outcome == .cancelled)
        #expect(h.checkpoints.saved.map(\.doneMs) == [30_000])
        #expect(try h.files.load(h.noteID)?.doneMs == 30_000)
    }

    @Test func cancellingTheRunsTaskCancelsTheJob() async throws {
        let h = try await Harness()
        h.transcriber.hangs = true
        let task = Task { await h.run().outcome }
        try await h.until("the transcription runs") { !h.transcriber.starts.isEmpty }
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test func volatileResultsReachTheDraft() async throws {
        let h = try await Harness()
        h.transcriber.volatileBeforeEachSegment = true
        let events = await h.run().events
        let drafts = events.compactMap { if case .draft(let words, let tentative) = $0 { (words, tentative) } else { nil } }
        #expect(!drafts.isEmpty)
        #expect(drafts.allSatisfy { $0.0.last?.text.hasPrefix("maybe") == true })
    }

    // ports: TranscriptionJobTest#missingModelsAreInstalledWithConsentAndADownloadFailureFailsTheJob
    @Test func missingModelsAreInstalledWithConsentAndADownloadFailureFailsTheJob() async throws {
        let installed = try await Harness(speechStatus: .notDownloaded)
        installed.transcriber.downloadsFirst = true
        let (outcome, events) = await installed.run()
        #expect(outcome == .done)
        #expect(events.contains { if case .downloading(let progress) = $0 { progress?.part == .speech } else { false } })

        for error in [DownloadError.noConnection, .notEnoughStorage] {
            let failed = try await Harness(speechStatus: .notDownloaded)
            failed.transcriber.failure = (-1, .failed(.download(error)))
            #expect(await failed.run().outcome == .downloadFailed(DownloadFailure(error: error, part: .speech)))
            #expect(failed.checkpoints.saved.isEmpty)
            #expect(await failed.note()?.transcript.isEmpty == true)
        }
    }

    @Test func aReadFailurePartWayFailsWithOpenAndKeepsTheCheckpoint() async throws {
        let h = try await Harness()
        h.transcriber.failure = (9, .failed(.open))
        #expect(await h.run().outcome == .failed(.open))
        #expect(h.checkpoints.saved.map(\.doneMs) == [30_000])
        #expect(try h.files.load(h.noteID)?.wordsComplete == false)
        #expect(await h.note()?.transcript.isEmpty == true)

        // An input that ends early without an error is not the end of the words either.
        let short = try await Harness()
        short.transcriber.endsBefore = 8
        #expect(await short.run().outcome == .failed(.open))
        #expect(short.checkpoints.saved.map(\.doneMs) == [30_000])
        #expect(await short.note()?.transcript.isEmpty == true)
        #expect(short.provenance(of: await short.note()) == nil)
    }

    @Test func aLongSilenceStillMovesTheCheckpointOn() async throws {
        let speech = ScriptedTranscriber.seventySeconds
        let silence = TranscriptSegment(text: "", start: 5, end: 60)
        let h = try await Harness(script: [speech[0], silence] + Array(speech[12...]))
        #expect(await h.run().outcome == .done)
        #expect(h.checkpoints.saved.map(\.doneMs) == [60_000, 70_000])
        #expect(await h.note()?.transcript.map(\.text) == [speech[0].text, speech[12].text, speech[13].text])
    }

    @Test func theInferenceTimeLeavesTheModelDownloadOut() async throws {
        let h = try await Harness(speechStatus: .notDownloaded)
        let uptime = ManualUptime()
        h.transcriber.downloadsFirst = true
        h.transcriber.onDownload = { uptime.advance(600_000) }
        h.transcriber.beforeSegment = { _ in uptime.advance(1_000) }
        #expect(await h.run(uptime: { uptime.value }).outcome == .done)
        let last = try #require(h.checkpoints.saved.last)
        #expect(last.inferenceMs == 14_000)
        #expect(last.elapsedMs == 14_000)
    }

    @Test func identifySpeakersKeepsAPausedTranscription() async throws {
        let h = try await Harness()
        let stop = StopSignal()
        h.transcriber.afterSegment = ScriptedTranscriber.stops(stop, at: 7)
        #expect(await h.run(stop: stop).outcome == .paused(.user))
        _ = try await h.notes.mutate(h.noteID) { $0.transcript = [TranscriptSegment(text: "Older", start: 0, end: 1)] }
        #expect(await h.run(kind: .speakersOnly).outcome == .done)
        #expect(try h.files.load(h.noteID)?.doneMs == 40_000, "the paused transcription keeps its checkpoint")

        h.transcriber.afterSegment = { _ in }
        #expect(await h.run().outcome == .done)
        #expect(h.transcriber.starts == [0, 39])
    }

    @Test func wordsEditedWhilePausedInTheSpeakerStepAreKept() async throws {
        let analyzer = FakeAnalyzer(suspends: true)
        let h = try await Harness(analyzer: analyzer)
        let stop = StopSignal()
        let running = Task { await h.run(stop: stop) }
        try await h.until("the speaker step runs") { analyzer.analyzeCount == 1 }
        stop.stop(.pause(.user))
        try await h.until("the stop cancels the analysis") { analyzer.cancelledWhileWaiting == 1 }
        analyzer.resume()
        #expect(await running.value.outcome == .paused(.user))
        let versions = await h.note()?.versions?.count
        _ = try await h.notes.mutate(h.noteID) { $0.transcript[0].text = "Edited"; $0.transcript[0].words = [] }

        #expect(await h.run().outcome == .done)
        let note = try #require(await h.note())
        #expect(note.transcript.first?.text == "Edited")
        #expect(note.versions?.count == versions, "no versions are added for words already saved")
        #expect(h.applied.count == 1)
    }

    /// Transcribe again adds a version whatever it hears, as Android adds a variant for every transcription.
    @Test func transcribingAgainAddsAVersionEvenForTheSameWords() async throws {
        let h = try await Harness()
        #expect(await h.run().outcome == .done)
        #expect(await h.note()?.versions?.map(\.kind) == [.transcription])
        #expect(await h.run().outcome == .done)
        let note = try #require(await h.note())
        #expect(note.versions?.map(\.kind) == [.transcription, .transcription])
        #expect(note.selectedVersionID == note.versions?.last?.id)
    }

    @Test func theProvenanceDescribesOnlyTheTranscriptTheRunMade() async throws {
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 70)],
                                       prints: [SpeakerPrint(speakerID: "a", model: "m:1", vector: [1], speechSeconds: 70)])
        let h = try await Harness(analyzer: FakeAnalyzer(analysis: analysis))
        let imported = [TranscriptSegment(text: "From the desktop", start: 0, end: 70)]
        _ = try await h.notes.mutate(h.noteID) { $0.transcript = imported }
        #expect(await h.run().outcome == .done)
        let note = try #require(await h.note())
        #expect(note.versions?.map(\.kind) == [.previous, .transcription])
        #expect(h.provenance(of: note)?.engine == "apple-speechtranscriber")

        let previous = try #require(note.versions?.first?.id), current = try #require(note.versions?.last?.id)
        let selected = try #require(try await h.notes.mutate(h.noteID) { $0.selectVersion(previous) })
        #expect(selected.transcript == imported)
        #expect(h.provenance(of: selected) == nil, "the desktop words are not the run's")
        let back = try #require(try await h.notes.mutate(h.noteID) { $0.selectVersion(current) })
        #expect(h.provenance(of: back)?.engine == "apple-speechtranscriber")
        let edited = try #require(try await h.notes.mutate(h.noteID) { $0.transcript[0].text = "Changed"; $0.transcript[0].words = [] })
        #expect(h.provenance(of: edited) == nil)
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
