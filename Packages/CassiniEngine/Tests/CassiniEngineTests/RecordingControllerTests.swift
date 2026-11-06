import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// RecordingController over a real NoteStore, with a scripted capture and fake storage, compression and hand-off.
@MainActor @Suite(.serialized) struct RecordingControllerTests {
    let floor = Limits.minRecordingFreeBytes

    // ports: RecordingControllerTest#finishNeverRunsOnTheMainThread (the iOS finish seals, compresses, then hands off)
    @Test func finishSealsTheNoteCompressesItAndHandsItOff() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        #expect(active.format == .pcm48kMono)
        let created = try #require(await h.note(active.noteID))
        #expect(created.audio == .live)
        #expect(created.audioFilename == "capture.caf")
        #expect(created.origin == .recorded)
        #expect(created.language == "", "a recording has no words, so no language, whatever Settings say")
        #expect(h.activity.started.map(\.noteID) == [active.noteID])
        h.capture.elapsed = 61

        h.controller.finish(title: "Monday meeting")
        let ended = try await h.awaitEnded()
        #expect(ended == .ended(noteID: active.noteID, outcome: .saved(.transcribe)))
        #expect(await h.note(active.noteID)?.status == .queued, "a kill before the hand-off leaves it interrupted")
        await h.controller.settle()
        let note = try #require(await h.note(active.noteID))
        #expect(note.audio == .plain)
        #expect(note.status == .queued, "the fake queue leaves the mark")
        #expect(note.title == "Monday meeting")
        #expect(note.duration == 2, "the duration read back from the file")
        #expect(note.waveform == [0.5, 0.5])
        #expect(note.audioFilename == "audio.m4a")
        let folder = h.store.directory(for: active.noteID)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("capture.caf").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))
        #expect(h.handoff.handedOff == [active.noteID])
        #expect(h.handoff.finalizing.isEmpty)
        #expect(h.controller.finalizing.isEmpty)
        #expect(!h.activity.isRunning)
    }

    // ports: RecordingControllerTest#titleEditsAreDebouncedAndKept
    @Test func titleEditsAreDebouncedAndKept() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        #expect(await h.note(active.noteID)?.title == active.defaultTitle)

        h.controller.setTitle("Test")
        h.controller.setTitle("Test del")
        h.controller.setTitle("Choir rehearsal ")
        try await h.waitFor("the title write") { await h.note(active.noteID)?.title == "Choir rehearsal" }
        try await Task.sleep(for: RecordingHarness.debounce * 2)
        #expect(h.notes.titleWrites == 1, "one write after the last change")
        #expect(try h.active.title == "Choir rehearsal ", "the state keeps the text as typed")
        #expect(h.activity.current?.title == "Choir rehearsal")

        h.controller.setTitle(String(repeating: "x", count: 250))
        #expect(try h.active.title.count == NoteTitles.maxLength, "the field stops at the title limit")
        h.controller.setTitle("Choir rehearsal")
        h.controller.finish()
        _ = try await h.awaitEnded()
        #expect(await h.note(active.noteID)?.title == "Choir rehearsal")
    }

    // ports: RecordingControllerTest#aBlankTitleBecomesTheDefault
    @Test func aBlankTitleBecomesTheDefault() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        #expect(active.defaultTitle == "Voice note 8 Oct, 09:41")
        #expect(await h.note(active.noteID)?.title == active.defaultTitle)
        #expect(h.activity.started.first?.state.title == active.defaultTitle, "the Live Activity shows the note's title")

        h.controller.finish(title: "   ")
        _ = try await h.awaitEnded()
        #expect(await h.note(active.noteID)?.title == "Voice note 8 Oct, 09:41")
    }

    // ports: RecordingControllerTest#storageLowAtFifteenMinutesThenStopAtTheFloor
    @Test func storageLowAtFifteenMinutesThenStopAtTheFloor() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let perSecond = RecordingPolicy.pcmBytesPerSecond + RecordingPolicy.finishBytesPerSecond
        let reserve = RecordingPolicy.finishReserve(elapsedMs: 5_000)
        h.storage.set(availableBytes: floor + reserve + 16 * 60 * perSecond)
        let active = try await h.startRecording()
        h.capture.elapsed = 5
        try await h.waitFor("5 s") { (try? h.active.elapsed) == 5 }
        #expect(try h.active.warning == nil)

        h.storage.set(availableBytes: floor + reserve + 15 * 60 * perSecond)
        try await h.waitFor("the warning") { (try? h.active.warning) != nil }
        #expect(try h.active.warning == .lowStorage(minutesLeft: 15))
        #expect(try h.active.space?.spaceMs == 15 * 60_000)
        try await h.waitFor("the Live Activity warning") { h.activity.current?.warning == .lowStorage(minutesLeft: 15) }

        h.storage.set(availableBytes: floor + reserve - 1)
        let ended = try await h.awaitEnded()
        #expect(ended == .ended(noteID: active.noteID, outcome: .stoppedForSpace))
        await h.controller.settle()
        #expect(await h.note(active.noteID)?.audio == .plain)
        #expect(h.handoff.handedOff.isEmpty, "a storage stop never enqueues")
    }

    // ports: RecordingControllerTest#aRecordingHasNoTimeLimitAndRenewsItsWakeLock (iOS has no wake lock)
    @Test func aRecordingHasNoTimeLimit() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.audio.set(summary: AudioSummary(duration: 100 * 3600, waveform: []))
        let active = try await h.startRecording()
        // Past the old 2 h cap, and far past it: the recording goes on, with no warning.
        for hours in [2.0, 3, 100] {
            h.capture.elapsed = hours * 3600
            try await h.waitFor("\(hours) h") { (try? h.active.elapsed) == hours * 3600 }
            #expect(try h.active.warning == nil)
        }
        // A paused recording does not advance its clock, and the policy still runs.
        h.controller.pause()
        #expect(try h.active.pause == .user)
        #expect(h.capture.isPaused)
        h.storage.set(availableBytes: floor - 1)
        let ended = try await h.awaitEnded()
        #expect(ended == .ended(noteID: active.noteID, outcome: .stoppedForSpace), "the policy runs while paused")
        #expect(await h.note(active.noteID)?.duration == 100 * 3600)
    }

    @Test func aRecordingTooLongToTranscribeStaysAudioOnly() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        h.capture.elapsed = 100 * 3600
        try await h.waitFor("100 h") { (try? h.active.elapsed) == 100 * 3600 }
        // The hint is the space only: 64 GiB at the measured rate, less the room the finish needs.
        let expected = RecordingSpace.of(usableBytes: 64 << 30,
                                         bytesPerSecond: RecordingPolicy.pcmBytesPerSecond + RecordingPolicy.finishBytesPerSecond,
                                         reserveBytes: RecordingPolicy.finishReserve(elapsedMs: 360_000_000))
        #expect(try h.active.space == expected)
        h.controller.finish()
        let ended = try await h.awaitEnded()
        #expect(ended == .ended(noteID: active.noteID, outcome: .saved(.audioOnly)))
        await h.controller.settle()
        #expect(await h.note(active.noteID)?.failure == .long)
        #expect(h.handoff.handedOff.isEmpty, "too long to transcribe: no hand-off")
    }

    // ports: RecordingControllerTest#microphoneFailureSavesTheAudioAndNeverEnqueues
    @Test(arguments: [CaptureEvent.failed, .mediaReset])
    func microphoneFailureSavesTheAudioAndNeverEnqueues(_ event: CaptureEvent) async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        h.capture.send(event)
        let ended = try await h.awaitEnded()
        #expect(ended == .ended(noteID: active.noteID, outcome: .microphoneFailed))
        await h.controller.settle()
        #expect(await h.note(active.noteID)?.audio == .plain)
        #expect(h.handoff.handedOff.isEmpty)
    }

    @Test func anAutomaticStopInTheBackgroundIsNotified() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        h.controller.isAppActive = false
        h.capture.send(.failed)
        _ = try await h.awaitEnded()
        try await h.waitFor("the notification") { !h.notifier.posted.isEmpty }
        #expect(h.notifier.posted == [ResultNotification(noteID: active.noteID, title: active.defaultTitle, kind: .microphoneFailed)])
    }

    @Test func aCaptureThatWroteNothingIsDiscarded() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.capture.capturedBytes = 0
        let active = try await h.startRecording()
        h.controller.finish()
        let ended = try await h.awaitEnded()
        #expect(ended == .ended(noteID: nil, outcome: .microphoneFailed))
        #expect(await h.note(active.noteID) == nil)
        #expect(!FileManager.default.fileExists(atPath: h.store.directory(for: active.noteID).path))
    }

    // ports: RecordingControllerTest#withoutConsentTheDownloadIsAskedOrTheNoteStaysAudioOnly
    @Test func withoutConsentTheDownloadIsAskedOrTheNoteStaysAudioOnly() async throws {
        let h = try RecordingHarness(consented: false); defer { h.tearDown() }
        let asked = try await h.startRecording()
        h.controller.finish()
        #expect(try await h.awaitEnded() == .ended(noteID: asked.noteID, outcome: .saved(.askConsent)))

        h.settings.recordDeclined()
        h.controller.dismissEnded()
        try await h.startRecording()
        h.controller.finish()
        guard case .ended(_, .saved(.audioOnly)) = try await h.awaitEnded() else { Issue.record("not audio only"); return }

        h.settings.recordConsent()
        h.settings.autoTranscribe = false
        h.controller.dismissEnded()
        try await h.startRecording()
        h.controller.finish()
        guard case .ended(_, .saved(.audioOnly)) = try await h.awaitEnded() else { Issue.record("not audio only"); return }
        await h.controller.settle()
        #expect(h.handoff.handedOff.isEmpty)
        #expect(await h.note(asked.noteID)?.audio == .plain)
    }

    // ports: RecordingControllerTest#aSilencedCaptureStaysPausedUntilTheUserResumes
    @Test func aSilencedCaptureStaysPausedUntilTheUserResumes() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        try await h.startRecording()

        h.capture.send(.interrupted)
        try await h.waitFor("the pause") { (try? h.active.pause) == .otherApp }
        #expect(h.capture.isPaused)
        #expect(h.activity.current?.isPaused == true)
        #expect(h.activity.current?.runningSince == nil)

        h.controller.resume()
        #expect(try h.active.pause == nil)
        #expect(!h.capture.isPaused)
        #expect(h.activity.current?.isPaused == false)

        // Resuming fails while another app holds the audio: the recording stays paused.
        h.capture.send(.interrupted)
        try await h.waitFor("the pause") { (try? h.active.pause) == .otherApp }
        h.capture.resumeError = CocoaError(.featureUnsupported)
        h.controller.resume()
        #expect(try h.active.pause == .otherApp)
        h.capture.resumeError = nil
        h.controller.resume()

        h.controller.pause()
        #expect(try h.active.pause == .user)
        h.capture.send(.interrupted)
        h.capture.send(.routeLost)
        try await h.eventsHandled()
        #expect(try h.active.pause == .user, "a user pause stays a user pause")
    }

    @Test func aLostInputPausesTheRecording() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        try await h.startRecording()
        h.capture.send(.routeLost)
        try await h.waitFor("the pause") { (try? h.active.pause) == .routeLost }
        #expect(h.capture.isPaused)
    }

    // ports: RecordingControllerTest#couldNotStartRemovesTheRow
    @Test func couldNotStartRemovesTheRow() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.capture.startError = CocoaError(.featureUnsupported)
        #expect(h.controller.start())
        #expect(try await h.awaitEnded() == .ended(noteID: nil, outcome: .couldNotStart))
        #expect(await h.store.all().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.root.path).isEmpty)
        #expect(h.activity.started.isEmpty)
    }

    // ports: RecordingControllerTest#oneRecordingAtATime
    @Test func oneRecordingAtATime() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        try await h.startRecording()
        #expect(!h.controller.start())
        h.controller.finish()
        _ = try await h.awaitEnded()
        #expect(h.controller.start())
        try await h.waitFor("the second recording") { h.controller.state.isActive }
        h.controller.finish()
        _ = try await h.awaitEnded()
        #expect(await h.store.all().count == 2)
    }

    @Test func aStartWaitsUntilTheAppIsReady() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.isReady = false
        #expect(h.controller.start())
        try await h.waitFor("the start waits for the app") { h.readyChecks >= 2 }
        #expect(h.controller.state == .starting)
        #expect(h.capture.starts == 0)
        h.isReady = true
        try await h.waitFor("the start") { h.controller.state.isActive }
    }

    // ports: RecordingControllerTest#levelsArePooledIntoBarsThatFollowTheCapturedTime
    @Test func levelsArePooledIntoBarsThatFollowTheCapturedTime() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        try await h.startRecording()
        h.capture.elapsed = 1
        h.capture.send(.level(0.5))
        try await h.waitFor("the loud bar") { h.controller.bars.levels.last == 0.5 }
        #expect(h.controller.bars.levels.count == WaveformBars.count)

        h.capture.elapsed = 1 + 3 * 0.125
        h.capture.send(.level(0))
        try await h.waitFor("the shift") { h.controller.bars.levels[WaveformBars.count - 4] == 0.5 }
        #expect(h.controller.bars.levels.last == 0)

        h.controller.pause()
        h.capture.send(.level(0.9))
        try await h.eventsHandled()
        #expect(h.controller.bars.levels.last == 0, "the bars freeze while paused")
    }

    @Test func aFailedCompressionKeepsTheOriginalAudio() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        var failed: [UUID] = []
        h.controller.onCompressionFailed = { failed.append($0) }
        h.audio.set(compressFails: true)
        let active = try await h.startRecording()
        h.controller.finish()
        _ = try await h.awaitEnded()
        await h.controller.settle()
        #expect(failed == [active.noteID])
        let note = try #require(await h.note(active.noteID))
        #expect(note.audioFilename == "capture.caf")
        #expect(FileManager.default.fileExists(atPath: h.store.audioURL(for: note).path))
        #expect(h.handoff.handedOff == [active.noteID], "the original audio is transcribed")
    }

    @Test func aRefusedHandOffMakesTheNoteAudioOnly() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.handoff.accepts = false
        let active = try await h.startRecording()
        h.controller.finish()
        _ = try await h.awaitEnded()
        await h.controller.settle()
        #expect(await h.note(active.noteID)?.status == .audioOnly)
    }

    // The note opens at once and shows "Waiting to transcribe" with Cancel while its audio is compressed.
    @Test func aTranscriptionCancelledWhileCompressingIsNotHandedOff() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.audio.set(held: true)
        let active = try await h.startRecording()
        h.controller.finish()
        #expect(try await h.awaitEnded() == .ended(noteID: active.noteID, outcome: .saved(.transcribe)))
        #expect(await h.note(active.noteID)?.status == .queued)
        _ = try await h.store.update(active.noteID) { $0.status = .audioOnly }
        h.audio.set(held: false)
        await h.controller.settle()
        #expect(h.handoff.handedOff.isEmpty, "the cancel stands")
        #expect(await h.note(active.noteID)?.status == .audioOnly)
        #expect(await h.note(active.noteID)?.audioFilename == "audio.m4a")
    }

    @Test func anUnreadableCaptureIsNotLeftQueued() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        h.audio.set(summary: nil)
        let active = try await h.startRecording()
        h.controller.finish()
        _ = try await h.awaitEnded()
        await h.controller.settle()
        let note = try #require(await h.note(active.noteID))
        #expect(note.status == .audioOnly)
        #expect(note.failure == .audio)
        #expect(h.handoff.handedOff.isEmpty)
    }

    @Test func aSealThatCannotBeWrittenStillShowsAPlainNote() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        let active = try await h.startRecording()
        h.capture.elapsed = 12
        h.notes.failUpdates = true
        h.controller.finish(title: "Standup")
        #expect(try await h.awaitEnded() == .ended(noteID: active.noteID, outcome: .saved(.audioOnly)))
        await h.controller.settle()
        let shown = try #require(h.notes.unsaved[active.noteID])
        #expect(shown.audio == .plain)
        #expect(shown.status == .audioOnly)
        #expect(!shown.isRecording)
        #expect(shown.title == "Standup")
        #expect(shown.duration == 12)
        #expect(await h.note(active.noteID)?.audio == .live, "recovery seals it at the next launch")
        #expect(h.audio.compressed.isEmpty)
        #expect(h.handoff.handedOff.isEmpty)
    }

    @Test func theCurrentTimeIsReadFromTheCapture() async throws {
        let h = try RecordingHarness(); defer { h.tearDown() }
        #expect(h.controller.currentElapsed == 0)
        try await h.startRecording()
        h.capture.elapsed = 3.25
        #expect(h.controller.currentElapsed == 3.25)
    }
}
