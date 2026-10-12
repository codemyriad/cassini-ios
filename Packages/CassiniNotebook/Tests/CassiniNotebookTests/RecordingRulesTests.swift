import Foundation
import Testing
import CassiniNotebook

@Suite struct WaveformBarsTests {
    // ports: RecordingControllerTest#levelsArePooledIntoBarsThatFollowTheCapturedTime
    @Test func levelsArePooledIntoBarsThatFollowTheCapturedTime() {
        var bars = WaveformBars()
        #expect(bars.levels.count == 56)
        bars.add(0.2, atMs: 1_000)
        bars.add(0.5, atMs: 1_050)
        bars.add(0.3, atMs: 1_100)
        #expect(bars.levels.last == 0.5)

        bars.add(0, atMs: 1_000 + 3 * WaveformBars.barMs)
        #expect(bars.levels[WaveformBars.count - 4] == 0.5)
        #expect(bars.levels.last == 0)
        #expect(bars.levels.count == 56)
    }

    @Test func barsStandStillWhileTheCapturedTimeDoes() {
        var bars = WaveformBars()
        bars.add(0.8, atMs: 2_000)
        let before = bars.levels
        // Paused: no captured time passes, so a later sample lands in the same bar.
        bars.add(0.1, atMs: 2_000)
        #expect(bars.levels == before)
    }

    @Test func aLongGapClearsEveryBarAndLevelsAreClamped() {
        var bars = WaveformBars()
        bars.add(1.7, atMs: 0)
        #expect(bars.levels.last == 1)
        bars.add(-1, atMs: 60_000)
        #expect(bars.levels.allSatisfy { $0 == 0 })
        bars.add(.nan, atMs: 60_000)
        #expect(bars.levels.last == 0)
    }
}

@Suite struct RecordingTitlesTests {
    let date = Date(timeIntervalSince1970: 1_791_452_460) // Thursday 8 October 2026, 09:41 UTC
    let utc = TimeZone(identifier: "UTC")!

    // ports: RecordingControllerTest#aBlankTitleBecomesTheDefault (the default's date, "Voice note 8 Oct, 08:14")
    @Test func theDefaultTitleDateIsDayMonthAnd24HourTime() {
        #expect(RecordingTitles.dateTime(date, locale: Locale(identifier: "en_US"), timeZone: utc) == "8 Oct, 09:41")
        #expect(RecordingTitles.dateTime(date, locale: Locale(identifier: "it_IT"), timeZone: utc) == "8 ott, 09:41")
        #expect(RecordingTitles.dateTime(date.addingTimeInterval(13 * 3600), locale: Locale(identifier: "en_US"), timeZone: utc) == "8 Oct, 22:41")
    }

    @Test func theRecoveredTitleDateIsDayAndMonth() {
        #expect(RecordingTitles.day(date, locale: Locale(identifier: "en_GB"), timeZone: utc) == "8 Oct")
    }
}

@Suite struct RecordingBannerTests {
    let active = ActiveRecording(noteID: UUID(), title: "Weekly sync", defaultTitle: "Voice note 8 Oct, 08:14", format: .pcm48kMono)

    func with(pause: RecordingPause? = nil, warning: RecordingWarning? = nil) -> RecordingState {
        var recording = active
        recording.pause = pause; recording.warning = warning
        return .active(recording)
    }

    // ports: RecordingViewModelTest#otherAppPauseAndWarningsShowTheirBanners
    @Test func otherAppPauseAndWarningsShowTheirBanners() {
        #expect(RecordingBanner.banners(state: with(), microphoneOff: false).isEmpty)
        #expect(RecordingBanner.banners(state: with(pause: .user), microphoneOff: false).isEmpty)
        #expect(RecordingBanner.banners(state: with(pause: .otherApp), microphoneOff: false) == [.pausedByOtherApp])
        #expect(RecordingBanner.banners(state: with(pause: .routeLost), microphoneOff: false) == [.inputLost])
        #expect(RecordingBanner.banners(state: with(warning: .lowStorage(minutesLeft: 10)), microphoneOff: false) == [.storageLow(minutes: 10)])
        #expect(RecordingBanner.pausedByOtherApp.action == .resume)
    }

    // ports: RecordingViewModelTest#aStorageStopStaysWithItsBannerAndOpensTheNote
    @Test func endedOutcomesShowTheirBannersWithTheirActions() {
        #expect(RecordingBanner.banners(state: .ended(noteID: UUID(), outcome: .stoppedForSpace), microphoneOff: false) == [.stoppedForSpace])
        #expect(RecordingBanner.banners(state: .idle, microphoneOff: false, ended: .microphoneFailed) == [.microphoneFailed])
        #expect(RecordingBanner.banners(state: .idle, microphoneOff: false, ended: .couldNotStart) == [.couldNotStart])
        #expect(RecordingBanner.banners(state: .idle, microphoneOff: false, ended: .saved(.transcribe)).isEmpty)
        #expect(RecordingBanner.stoppedForSpace.action == .openNote)
        #expect(RecordingBanner.microphoneFailed.action == .openNote)
        #expect(RecordingBanner.couldNotStart.action == .tryAgain)
        #expect(RecordingBanner.microphoneOff.action == .openSettings)
    }

    @Test func errorsComeBeforeWarnings() {
        #expect(RecordingBanner.banners(state: with(pause: .otherApp, warning: .lowStorage(minutesLeft: 5)), microphoneOff: true)
                == [.microphoneOff, .pausedByOtherApp, .storageLow(minutes: 5)])
        #expect(RecordingBanner.banners(state: .idle, microphoneOff: true, ended: .stoppedForSpace).first == .microphoneOff)
    }

    @Test func onlyACaptureInProgressIsInProgress() {
        #expect(RecordingState.starting.inProgress)
        #expect(with().inProgress)
        #expect(RecordingState.finishing(noteID: UUID()).inProgress)
        #expect(!RecordingState.idle.inProgress)
        #expect(!RecordingState.ended(noteID: nil, outcome: .couldNotStart).inProgress)
    }
}
