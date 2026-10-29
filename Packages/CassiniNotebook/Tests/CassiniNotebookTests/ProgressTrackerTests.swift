import Foundation
import Synchronization
import Testing
import CassiniNotebook

@Suite struct ProgressTrackerTests {
    // MARK: Phases

    // ports: ProgressTrackerTest#phaseFollowsTheJobBeforeTranscribing
    @Test func phaseFollowsTheJobBeforeTranscribing() {
        var t = Tracked()
        #expect(t.phase == .starting)
        t.send(.downloading(nil))
        #expect(t.phase == .downloading(nil))
        let progress = DownloadProgress(part: .speech, doneBytes: 10, totalBytes: 100, verifying: false)
        t.send(.downloading(progress))
        #expect(t.phase == .downloading(progress))
        t.send(.waitingForPrevious)
        #expect(t.phase == .waitingForPrevious)
        t.send(started())
        guard case .transcribing = t.phase else { Issue.record("Not transcribing: \(t.phase)"); return }
        t.send(.ended(.failed(.checkpointMismatch)))
        #expect(t.tracker.outcome == .failed(.checkpointMismatch))
    }

    // ports: ProgressTrackerTest#stoppingStaysUntilTheEndAndStopsTheTicks
    @Test func stoppingStaysUntilTheEndAndStopsTheTicks() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.advance(1_500)
        t.send(.stopping)
        #expect(t.phase == .stopping)
        let reads = t.battery.reads.count
        t.send(.windowDone(doneMs: 28_000, totalMs: 70_000, words: words(0, 28)))
        t.send(.stageChanged(.saving))
        t.advance(30_000)
        #expect(t.phase == .stopping)
        #expect(t.battery.reads.count == reads)
        t.send(.ended(.paused(.user)))
        #expect(t.phase == .stopping)
        #expect(t.tracker.outcome == .paused(.user))
        #expect(!t.tracker.isTicking)
    }

    // ports: ProgressTrackerTest#aStopBeforeInferenceKeepsStopping
    @Test func aStopBeforeInferenceKeepsStopping() {
        var t = Tracked()
        t.send(.stopping)
        t.send(started())
        t.advance(5_000)
        #expect(t.phase == .stopping)
        #expect(t.battery.reads.isEmpty)
    }

    // ports: ProgressTrackerTest#publishesOncePerSecondWhileTranscribing
    @Test func publishesOncePerSecondWhileTranscribing() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.advance(300)
        t.send(.windowDone(doneMs: 28_000, totalMs: 70_000, words: words(0, 28)))
        t.advance(699)
        #expect(t.progress?.doneMs == 0)
        t.advance(1)
        #expect(t.progress?.doneMs == 28_000)
        #expect(t.progress?.words == 28)
    }

    // ports: ProgressTrackerTest#refreshPublishesTheNamesAtOnce (adapted: iOS applies the draft names where the draft
    // is shown, `DraftView`, so they need no publish; a refresh publishes the latest draft at once)
    @Test func aRefreshPublishesTheDraftAtOnce() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.advance(200)
        t.send(.draft(words: words(0, 3), tentativeFromMs: 1_000))
        #expect(t.draft?.words.isEmpty == true)
        t.refresh()
        #expect(t.draft?.words.count == 3)
        #expect(t.draft?.tentativeFromMs == 1_000)
    }

    // MARK: Elapsed time and resume

    // ports: ProgressTrackerTest#elapsedIsTheCheckpointElapsedPlusTheRunTimeAndBatteryIsReadEvery10Seconds
    @Test func elapsedIsTheCheckpointElapsedPlusTheRunTimeAndBatteryIsReadEvery10Seconds() {
        var t = Tracked()
        t.send(started(totalMs: 70_000, restored: restored(28_000, 70_000, words(0, 28), elapsed: 50_000)))
        t.advance(25_000)
        #expect(t.battery.reads == [50_000, 60_000, 70_000])
    }

    // ports: ProgressTrackerTest#restoreStartsFromTheCheckpointAndRecalculates
    @Test func restoreStartsFromTheCheckpointAndRecalculates() {
        var t = Tracked()
        t.send(started(totalMs: 70_000, restored: restored(28_000, 70_000, words(0, 28), elapsed: 50_000), speakers: false))
        #expect(t.progress?.percent == 40)
        #expect(t.progress?.words == 28)
        #expect(t.progress?.doneMs == 28_000)
        #expect(t.draft?.words.count == 28)
        #expect(t.draft?.tentativeFromMs == 26_000)
        #expect(t.progress?.step == .reading)
        // The first result after a resume includes the model reload: it does not count towards the 3 results.
        t.windows(54_000, 62_000)
        #expect(t.progress?.timeLeft == .calculating)
        t.windows(66_000)
        #expect(t.progress?.timeLeft.isRange == true)
    }

    // MARK: Stepper and headline

    // ports: ProgressTrackerTest#theStepIsMonotonicAndTheHeadlineNeverGoesBackToReading
    @Test func theStepIsMonotonicAndTheHeadlineNeverGoesBackToReading() {
        var t = Tracked()
        t.send(started(totalMs: 120_000))
        t.send(.reading(readMs: 10_000, totalMs: 120_000))
        t.tick()
        #expect(t.progress?.step == .reading)
        #expect(t.progress?.headline == .readingAudio)
        #expect(t.progress?.rangeEndMs == 10_000)
        t.send(.stageChanged(.preparing, startMs: 0, endMs: 28_000))
        t.tick()
        #expect(t.progress?.step == .preparing)
        #expect(t.progress?.headline == .preparing)
        t.send(.stageChanged(.words, startMs: 0, endMs: 28_000))
        t.send(.windowDone(doneMs: 28_000, totalMs: 120_000, words: words(0, 28)))
        // Reading more audio, and a stray earlier stage, never move the stepper or the headline back.
        t.send(.reading(readMs: 40_000, totalMs: 120_000))
        t.send(.stageChanged(.preparing, startMs: 26_000, endMs: 54_000))
        for _ in 0..<3 {
            t.tick()
            #expect(t.progress?.step == .words)
            #expect(t.progress?.headline == .findingWords)
            #expect(t.progress?.rangeStartMs == 0)
            #expect(t.progress?.rangeEndMs == 28_000)
        }
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 0))
        t.tick()
        #expect(t.progress?.step == .speakers)
        #expect(t.progress?.headline == .findingSpeakers)
        t.send(.stageChanged(.matching))
        t.tick()
        #expect(t.progress?.step == .speakers)
        #expect(t.progress?.headline == .matchingVoices)
        #expect(t.progress?.speakersSkipped == false)
        t.send(.stageChanged(.saving))
        t.send(.stageChanged(.words))
        t.tick()
        #expect(t.progress?.step == .saving)
        #expect(t.progress?.headline == .saving)
        #expect(t.progress?.speakersSkipped == false)
    }

    // ports: ProgressTrackerTest#theHeadlineFollowsTheStepperWithinTheStageDebounce
    @Test func theHeadlineFollowsTheStepperWithinTheStageDebounce() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.send(.reading(readMs: 27_000, totalMs: 70_000))
        t.tick()
        #expect(t.progress?.headline == .readingAudio)
        // 100 ms later the stage debounce still shows Reading; the stepper is already at Words.
        t.send(.stageChanged(.words, startMs: 0, endMs: 28_000))
        t.advance(100)
        t.refresh()
        #expect(t.progress?.step == .words)
        #expect(t.progress?.headline == .findingWords)
        #expect(t.progress?.rangeEndMs == 28_000)
        // Within one step the debounce holds: a Matching stage 100 ms long keeps the Speakers range.
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 70_000))
        t.tick()
        t.send(.stageChanged(.matching))
        t.advance(100)
        t.refresh()
        #expect(t.progress?.headline == .findingSpeakers)
        #expect(t.progress?.rangeEndMs == 70_000)
    }

    // ports: ProgressTrackerTest#findingWordsWithoutADiarizer
    @Test func findingWordsWithoutTheSpeakerStep() {
        var t = Tracked()
        t.send(started(totalMs: 70_000, speakers: false))
        t.send(.stageChanged(.words, startMs: 0, endMs: 28_000))
        t.tick()
        #expect(t.progress?.headline == .findingWords)
        #expect(t.progress?.speakersSkipped == true)
    }

    // ports: ProgressTrackerTest#speakersUnavailableSwitchesToFindingWords (adapted: on iOS the speaker step comes after
    // the words, so a failure before it skips the step)
    @Test func speakersUnavailableBeforeTheStepSkipsIt() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.send(.stageChanged(.words, startMs: 0, endMs: 28_000))
        t.tick()
        #expect(t.progress?.speakersSkipped == false)
        t.send(.speakersUnavailable)
        t.tick()
        #expect(t.progress?.speakersSkipped == true)
    }

    // ports: ProgressTrackerTest#matchingAfterAMidRunSpeakerFailureIsNeverDrawnAsSkipped
    @Test func aSpeakerStepThatFailsIsNeverDrawnAsSkipped() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 28_000))
        t.send(.speakersUnavailable)
        t.tick()
        #expect(t.progress?.speakersSkipped == false)
        t.send(.stageChanged(.saving))
        t.tick()
        #expect(t.progress?.speakersSkipped == false)
    }

    // ports: ProgressTrackerTest#matchingIsSkippedWithoutTheVoiceprintModelOrWhenSavingBeginsWithoutIt
    @Test func speakersAreSkippedWithoutTheStepOrWhenSavingBeginsWithoutIt() {
        var none = Tracked()
        none.send(started(totalMs: 70_000, speakers: false))
        #expect(none.progress?.speakersSkipped == true)

        var unused = Tracked()
        unused.send(started(totalMs: 70_000))
        #expect(unused.progress?.speakersSkipped == false)
        unused.send(.stageChanged(.saving))
        unused.tick()
        #expect(unused.progress?.speakersSkipped == true)
    }

    // ports: ProgressTrackerTest#theLowMemoryHintIsCarried
    @Test func theLowMemoryHintIsCarried() {
        var t = Tracked()
        t.send(.started(JobStart(totalMs: 70_000, speakers: true, prints: true, lowMemory: true)))
        #expect(t.progress?.lowMemory == true)
    }

    // MARK: Percent and time left

    // ports: ProgressTrackerTest#percentIsCappedAt99UntilDone
    @Test func percentIsCappedAt99UntilDone() {
        var t = Tracked()
        t.send(started(totalMs: 70_000, speakers: false))
        #expect(t.progress?.percent == 0)
        t.windows(28_000, 54_000)
        #expect(t.progress?.percent == 77)
        t.windows(70_000)
        #expect(t.progress?.percent == 99)
        #expect(t.progress?.timeLeft == .finishing)
        t.send(.stageChanged(.saving))
        t.tick()
        #expect(t.progress?.percent == 99)
        t.send(.ended(.done))
        #expect(t.progress?.percent == 100)
        #expect(t.progress?.timeLeft == .finishing)
    }

    @Test func theWordsFillTheBarTo85AndTheSpeakersTo99() {
        var t = Tracked()
        t.send(started(totalMs: 100_000))
        t.windows(50_000, totalMs: 100_000)
        #expect(t.progress?.percent == 42)
        t.windows(100_000, totalMs: 100_000)
        #expect(t.progress?.percent == 85)
        // The speaker step has not begun: its time is not known yet.
        #expect(t.progress?.timeLeft == .calculating)
        t.send(.namingClosed(matching: true))
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 0))
        t.tick()
        #expect(t.progress?.percent == 85)
        t.advance(4_000)
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 50_000))
        t.tick()
        #expect(t.progress?.percent == 92)
        #expect(t.progress?.timeLeft.isRange == true)
        // A later stage with no range never takes the bar back.
        t.send(.stageChanged(.matching))
        t.tick()
        #expect(t.progress?.percent == 99)
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 10_000))
        t.tick()
        #expect(t.progress?.percent == 99)
    }

    // ports: ProgressTrackerTest#percentIsIndeterminateWhileTheTotalIsUnknown
    @Test func percentIsIndeterminateWhileTheTotalIsUnknown() {
        var t = Tracked()
        t.send(started(totalMs: 0))
        #expect(t.progress?.percent == nil)
        t.send(.reading(readMs: 5_000, totalMs: 90_000))
        t.tick()
        #expect(t.progress?.percent == 0)
    }

    // ports: ProgressTrackerTest#timeLeftIsCalculatingUntilThreeWindowsAndTheTotalIsKnown
    @Test func timeLeftIsCalculatingUntilThreeResultsAndTheTotalIsKnown() {
        var unknown = Tracked()
        unknown.send(started(totalMs: 0))
        for done: Int64 in [28_000, 54_000, 80_000, 106_000] {
            unknown.advance(10_000)
            unknown.send(.windowDone(doneMs: done, totalMs: 0, words: words(0, Int(done / 1000))))
        }
        unknown.tick()
        #expect(unknown.progress?.timeLeft == .calculating)

        var known = Tracked()
        known.send(started(totalMs: 300_000))
        known.windows(28_000, 54_000, totalMs: 300_000)
        #expect(known.progress?.timeLeft == .calculating)
        known.windows(80_000, totalMs: 300_000)
        #expect(known.progress?.timeLeft.isRange == true)
    }

    // ports: ProgressTrackerTest#theRangeIncludesTheFinalizationEstimate
    @Test func theRangeIncludesTheFinalizationEstimate() {
        let finalizationMs: Int64 = 90_000
        var t = Tracked(finalizationMs: finalizationMs)
        var reference = TranscriptionProgress(totalMs: 600_000)
        t.send(started(totalMs: 600_000))
        for done: Int64 in [28_000, 54_000, 80_000, 106_000] {
            t.advance(10_000)
            t.send(.windowDone(doneMs: done, totalMs: 600_000, words: words(0, 4)))
            reference.complete(done: done, total: 600_000, words: 4, at: t.now)
        }
        t.tick()
        let snapshot = reference.snapshot(at: t.now)
        let expected = TimeLeft.range(
            lowMs: TranscriptionProgress.roundedRemaining(snapshot.remainingLowMs! + finalizationMs),
            highMs: TranscriptionProgress.roundedRemaining(snapshot.remainingHighMs! + finalizationMs))
        #expect(t.progress?.timeLeft == expected)
    }

    // MARK: Battery

    // ports: ProgressTrackerTest#batteryIsHiddenWithoutAReading
    @Test func batteryIsHiddenWithoutAReading() {
        var t = Tracked(battery: Battery { _ in nil })
        t.send(started(totalMs: 70_000))
        #expect(t.progress?.battery == .unavailable)
    }

    // ports: ProgressTrackerTest#batteryIsPluggedInWhileCharging
    @Test func batteryIsPluggedInWhileCharging() {
        var t = Tracked(battery: Battery { .init(elapsedMs: $0, percent: 64, charging: true) })
        t.send(started(totalMs: 70_000))
        #expect(t.progress?.battery == .pluggedIn(percentNow: 64))
    }

    // ports: ProgressTrackerTest#batteryMeasuresFor120SecondsThenProjects
    @Test func batteryMeasuresFor120SecondsThenProjects() {
        // 1 % every 60 s of run time.
        var t = Tracked(battery: Battery { .init(elapsedMs: $0, percent: 80 - Int($0 / 60_000), charging: false) })
        t.send(started(totalMs: 3_600_000))
        #expect(t.progress?.battery == .measuring(percentNow: 80))
        var done: Int64 = 0
        for _ in 0..<11 {
            t.advance(10_000)
            done += 26_000
            t.send(.windowDone(doneMs: done, totalMs: 3_600_000, words: words(0, 4)))
        }
        t.tick()
        #expect(t.progress?.timeLeft.isRange == true)
        #expect(t.progress?.battery == .measuring(percentNow: 79))
        t.advance(10_000)
        t.tick()
        guard case .projected(let now, let atFinish) = t.progress?.battery else {
            Issue.record("Not projected: \(String(describing: t.progress?.battery))"); return
        }
        #expect(now == 78)
        #expect(atFinish < 78)
    }

    // ports: ProgressTrackerTest#aSmallDropKeepsMeasuring
    @Test func aSmallDropKeepsMeasuring() {
        var t = Tracked(battery: Battery { .init(elapsedMs: $0, percent: 80, charging: false) })
        t.send(started(totalMs: 3_600_000))
        var done: Int64 = 0
        for _ in 0..<20 {
            t.advance(10_000)
            done += 26_000
            t.send(.windowDone(doneMs: done, totalMs: 3_600_000, words: words(0, 4)))
        }
        t.tick()
        #expect(t.progress?.battery == .measuring(percentNow: 80))
    }

    // ports: ProgressTrackerTest#aResumedRunMeasuresBatteryAgain
    @Test func aResumedRunMeasuresBatteryAgain() {
        var t = Tracked(battery: Battery { .init(elapsedMs: $0, percent: 90 - Int($0 / 30_000), charging: false) })
        // The checkpoint's 10 minutes of elapsed time are not this run's measurement.
        t.send(started(totalMs: 3_600_000, restored: restored(600_000, 3_600_000, [], elapsed: 600_000)))
        var done: Int64 = 600_000
        for _ in 0..<5 {
            t.advance(10_000)
            done += 26_000
            t.send(.windowDone(doneMs: done, totalMs: 3_600_000, words: words(0, 4)))
        }
        t.tick()
        #expect(t.progress?.timeLeft.isRange == true)
        guard case .measuring = t.progress?.battery else {
            Issue.record("Not measuring: \(String(describing: t.progress?.battery))"); return
        }
    }

    // MARK: Draft

    // ports: ProgressTrackerTest#tentativeFollowsTheDoneWindowAndSettlesWhenTheDecodeIsComplete
    @Test func tentativeFollowsTheDoneAudioAndSettlesWhenTheWordsAreFinal() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.windows(28_000)
        #expect(t.draft?.tentativeFromMs == 26_000)
        t.windows(54_000)
        #expect(t.draft?.tentativeFromMs == 52_000)
        t.windows(70_000)
        t.send(.namingClosed(matching: true))
        t.tick()
        #expect(t.draft?.tentativeFromMs == .max)
        #expect(t.draft?.namingOpen == false)
    }

    // ports: ProgressTrackerTest#draftAppliesMergesAndLabelPrecedence (the names applied by `DraftView`)
    @Test func draftAppliesMergesAndLabelPrecedence() throws {
        var t = Tracked()
        let names = DraftNames(labels: ["c": "Carla"], merges: ["d": "b"], automatic: ["b": "Bruno"])
        t.send(started(totalMs: 70_000))
        let spoken = [("a", 0, "uno"), ("d", 1_000, "due"), ("c", 2_000, "tre"), ("e", 3_000, "quattro"), ("b", 4_000, "cinque")]
            .map { DraftWord(speaker: $0.0, startMs: Int64($0.1), endMs: Int64($0.1) + 500, text: $0.2) }
        t.send(.windowDone(doneMs: 28_000, totalMs: 70_000, words: spoken))
        t.tick()
        let draft = DraftView.build(try #require(t.draft), names: names, voiceNames: [:])
        #expect(draft.words.map(\.speaker) == ["a", "b", "c", "e", "b"])
        #expect(draft.labels == ["a": "Speaker 1", "b": "Bruno", "c": "Carla", "e": "Speaker 4"])
        #expect(draft.automatic == ["b"])
        #expect(draft.tentativeFromMs == 26_000)
        #expect(draft.namingOpen)
    }

    // ports: ProgressTrackerTest#suggestionsOnlyForPlaceholderSpeakersWithALiveSuggestedMatch
    @Test func suggestionsOnlyForPlaceholderSpeakersWithALiveSuggestedMatch() throws {
        var t = Tracked()
        let luca = UUID(), ada = UUID(), deleted = UUID()
        let voices = [luca: "Luca", ada: "Ada", UUID(): "Gone"]
        var names = DraftNames(labels: ["named": "Nora"], automatic: ["auto": "Ada"], live: [
            "a": LiveMatch(luca, 0.61, .suggested), "named": LiveMatch(luca, 0.62, .suggested),
            "auto": LiveMatch(ada, 0.9, .auto), "confirmed": LiveMatch(ada, 0.7, .confirmed),
            "rejected": LiveMatch(luca, 0.6, .suggested), "missing": LiveMatch(deleted, 0.6, .suggested),
        ], rejected: ["rejected": [luca]])
        t.send(started(totalMs: 70_000))
        let speakers = ["a", "named", "auto", "confirmed", "rejected", "missing", "a", "b", "a"]
        let spoken = speakers.enumerated().map {
            DraftWord(speaker: $0.element, startMs: Int64($0.offset) * 1000, endMs: Int64($0.offset) * 1000 + 500,
                      text: "w\($0.offset)")
        }
        t.send(.windowDone(doneMs: 28_000, totalMs: 70_000, words: spoken))
        t.tick()
        let draft = try #require(t.draft)
        // Speaker a's latest turn starts at 8 s; the other speakers have a label, an automatic name, a confirmed match,
        // a rejected voice or a voice that no longer exists.
        #expect(DraftView.build(draft, names: names, voiceNames: voices).suggestions
                == [DraftSuggestion(speakerID: "a", voiceID: luca, name: "Luca", score: 0.61, atMs: 8_000)])
        // A merge into a: the turn at 6 s and 7 s is a's too, starting at 6 s.
        names.merges = ["b": "a"]
        #expect(DraftView.build(draft, names: names, voiceNames: voices).suggestions.map(\.atMs) == [6_000])
        // "Not Luca" removes the card.
        names = names.reject("a", voice: luca, voiceName: "Luca")
        #expect(DraftView.build(draft, names: names, voiceNames: voices).suggestions.isEmpty)
    }

    // ports: ProgressTrackerTest#noSuggestionsOnceNamingIsClosed
    @Test func noSuggestionsOnceNamingIsClosed() throws {
        var t = Tracked()
        let luca = UUID()
        let names = DraftNames(live: ["a": LiveMatch(luca, 0.6, .suggested)])
        t.send(started(totalMs: 70_000))
        t.send(.windowDone(doneMs: 28_000, totalMs: 70_000, words: words(0, 28)))
        t.tick()
        #expect(DraftView.build(try #require(t.draft), names: names, voiceNames: [luca: "Luca"]).suggestions.count == 1)
        t.send(.namingClosed(matching: true))
        t.tick()
        let closed = DraftView.build(try #require(t.draft), names: names, voiceNames: [luca: "Luca"])
        #expect(closed.suggestions.isEmpty)
        #expect(!closed.namingOpen)
    }

    // ports: CheckpointRepositoryTest#draftTreatsAStoredPlaceholderAsNoName (iOS applies the names in `DraftView`)
    @Test func theDraftTreatsAStoredPlaceholderAsNoName() throws {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        let spoken = ["S1", "S2", "S3"].enumerated().map {
            DraftWord(speaker: $0.element, startMs: Int64($0.offset) * 1000, endMs: Int64($0.offset) * 1000 + 500, text: "w")
        }
        t.send(.windowDone(doneMs: 28_000, totalMs: 70_000, words: spoken))
        t.tick()
        // As a names.json written elsewhere could hold them: placeholders are not names.
        let names = DraftNames(labels: ["S1": "Speaker 1", "S2": "Voce 2", "S3": "Anna"], automatic: ["S1": "Luca"])
        let draft = DraftView.build(try #require(t.draft), names: names, voiceNames: [:])
        #expect(draft.labels == ["S1": "Luca", "S2": "Speaker 2", "S3": "Anna"])
        #expect(draft.automatic == ["S1"])
    }

    @Test func volatileWordsReplaceTheDraftUntilTheNextResult() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.windows(28_000)
        t.send(.draft(words: words(0, 30), tentativeFromMs: 28_000))
        t.tick()
        #expect(t.draft?.words.count == 30)
        #expect(t.draft.map { $0.words.filter($0.isTentative).count } == 2)
        #expect(t.progress?.words == 28)
    }

    @Test func identifySpeakersFillsTheBarWithTheSpeakerStepAlone() {
        var t = Tracked()
        t.send(started(totalMs: 70_000))
        t.send(.namingClosed(matching: true))
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 0))
        t.tick()
        #expect(t.progress?.percent == 0)
        t.send(.stageChanged(.speakers, startMs: 0, endMs: 35_000))
        t.tick()
        #expect(t.progress?.percent == 49)
        #expect(t.progress?.doneMs == 35_000, "Processed is the analysed audio")
        #expect(t.progress?.step == .speakers)

        // A run that resumes in the speaker step keeps the words' share.
        var resumed = Tracked()
        resumed.send(started(totalMs: 70_000, restored: restored(70_000, 70_000, words(0, 70), elapsed: 60_000)))
        resumed.send(.namingClosed(matching: true))
        resumed.send(.stageChanged(.speakers, startMs: 0, endMs: 35_000))
        resumed.tick()
        #expect(resumed.progress?.percent == 92)
        #expect(resumed.progress?.doneMs == 70_000)
    }

    // MARK: Helpers

    private func started(totalMs: Int64 = 70_000, restored: RestoredCheckpoint? = nil, speakers: Bool = true) -> JobEvent {
        .started(JobStart(totalMs: totalMs, restored: restored, speakers: speakers, prints: speakers))
    }

    private func restored(_ doneMs: Int64, _ totalMs: Int64, _ words: [DraftWord], elapsed: Int64) -> RestoredCheckpoint {
        RestoredCheckpoint(doneMs: doneMs, totalMs: totalMs, words: words, elapsedMs: elapsed)
    }
}

/// One word a second from `from` (inclusive) to `to` (exclusive), all one voice.
private func words(_ from: Int, _ to: Int) -> [DraftWord] {
    (from..<to).map { DraftWord(speaker: "a", startMs: Int64($0) * 1000, endMs: Int64($0) * 1000 + 500, text: "w\($0)") }
}

/// A scripted battery that records when it was read.
private final class Battery: Sendable {
    private let level: @Sendable (Int64) -> BatteryProjection.Reading?
    private let readTimes = Mutex<[Int64]>([])
    init(_ level: @escaping @Sendable (Int64) -> BatteryProjection.Reading?) { self.level = level }
    var reads: [Int64] { readTimes.withLock { $0 } }
    func read(_ elapsedMs: Int64) -> BatteryProjection.Reading? {
        readTimes.withLock { $0.append(elapsedMs) }
        return level(elapsedMs)
    }
}

/// A tracker driven as the app drives it: events at the current time and a tick every second after `started`.
private struct Tracked {
    let battery: Battery
    var tracker: ProgressTracker
    private(set) var now: Int64 = 0
    private var startedAt: Int64?

    init(finalizationMs: Int64 = 0, battery: Battery = Battery { .init(elapsedMs: $0, percent: 50, charging: false) }) {
        self.battery = battery
        tracker = ProgressTracker(finalizationMs: finalizationMs, battery: { battery.read($0) })
    }

    var phase: JobPhase { tracker.phase }
    var progress: RunningProgress? { if case .transcribing(let progress, _) = phase { progress } else { nil } }
    var draft: DraftState? { if case .transcribing(_, let draft) = phase { draft } else { nil } }

    mutating func send(_ event: JobEvent) {
        if case .started = event, startedAt == nil { startedAt = now }
        tracker.apply(event, at: now)
    }

    /// Moves time forward, ticking at every whole second since `started`.
    mutating func advance(_ ms: Int64) {
        let end = now + ms
        if let startedAt {
            var next = startedAt + ((now - startedAt) / 1000 + 1) * 1000
            while next <= end {
                now = next
                if tracker.isTicking { tracker.tick(at: now) }
                next += 1000
            }
        }
        now = end
    }

    /// Past the next tick and the stage debounce.
    mutating func tick() { advance(1_000) }

    mutating func refresh() { tracker.tick(at: now) }

    /// Results at each of `done`, 10 s of run time apart, then one tick.
    mutating func windows(_ done: Int64..., totalMs: Int64 = 70_000) {
        for value in done {
            advance(10_000)
            send(.windowDone(doneMs: value, totalMs: totalMs, words: words(0, Int(value / 1000))))
        }
        tick()
    }
}

private extension TimeLeft {
    var isRange: Bool { if case .range = self { true } else { false } }
}
