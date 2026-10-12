import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// PlaybackController with a fake player on virtual time: the position, the saves (every 5 s, final on pause and
/// leave), interruptions and lost outputs, the reload after the audio changed, ownership and speaker samples.
///
/// iOS opens a file synchronously, so Android's races of an open or a reload overtaken while its file prepares cannot
/// happen; those tests keep their order of events and check the same outcome.
@MainActor @Suite struct PlaybackControllerTests {
    typealias Save = FakePlaybackPositions.Save

    let player = FakePlayback(fileDuration: 60)
    let positions = FakePlaybackPositions()
    let ticker = ManualTicker()
    let controller: PlaybackController
    let note = UUID()
    let other = UUID()
    let audio = URL(fileURLWithPath: "/notes/capture.caf")

    init() {
        let player = player, ticker = ticker
        ticker.onAdvance = { player.advance(by: $0) }
        controller = PlaybackController(parts: .init(player: player, positions: positions, ticker: ticker,
                                                     uptime: { ticker.seconds }))
    }

    private func source(_ noteID: UUID, _ url: URL? = nil) -> PlaybackSource {
        PlaybackSource(noteID: noteID, url: url ?? audio, title: "Note")
    }

    private func advance(_ milliseconds: Int) { ticker.advance(byMilliseconds: milliseconds) }

    private func saves() async -> [Save] {
        await controller.settle()
        return positions.saves
    }

    private var milliseconds: Int { Int((controller.state.position * 1000).rounded()) }

    private func waitFor(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // ports: PlaybackControllerTest#thePositionIsSavedEveryFiveSecondsAndFinallyOnPauseAndLeave
    @Test func thePositionIsSavedEveryFiveSecondsAndFinallyOnPauseAndLeave() async {
        #expect(controller.open(source(note), at: 1))
        #expect(milliseconds == 1_000)

        controller.play()
        #expect(player.holdsSession)
        advance(1_000)
        #expect(controller.state.isPlaying)
        #expect((1_850...2_000).contains(milliseconds), "the position follows playback: \(milliseconds)")

        // Ticks every 150 ms: the 5 s saves come at 5.1 s and 10.2 s of playback.
        advance(9_300)
        var saved = await saves()
        #expect(saved.map(\.final) == [false, false])
        #expect(saved.map(\.milliseconds) == [6_100, 11_200])

        controller.pause()
        saved = await saves()
        #expect(saved.last?.milliseconds == 11_300)
        #expect(saved.last?.final == true)
        #expect(!player.holdsSession, "the audio session is given back")
        let count = saved.count
        advance(20_000)
        #expect(await saves().count == count, "no saves while paused")

        controller.seek(to: 30)
        controller.leave()
        #expect(await saves().last == Save(note, 30, final: true))
        #expect(player.loadedURL == nil)
        #expect(player.unloads == 1)
        #expect(controller.state == PlaybackState())
    }

    // ports: PlaybackControllerTest#focusLossAndUnpluggedHeadphonesPause
    @Test func anotherAppTakingTheAudioAndUnpluggedHeadphonesPause() async throws {
        controller.open(source(note), at: 0)
        controller.play()
        advance(2_000)
        player.interrupt(.interrupted)
        try await waitFor("the interruption") { !controller.state.isPlaying }
        #expect(await saves().last == Save(note, 2, final: true))

        controller.play()
        advance(1_000)
        player.interrupt(.routeLost)
        try await waitFor("the lost output") { !controller.state.isPlaying }
        #expect(await saves().last?.milliseconds == 3_000)
        #expect(positions.saves.last?.final == true)
        #expect(!player.holdsSession)
    }

    // ports: PlaybackControllerTest#aSpeakerSampleRestoresThePreviousPosition
    @Test func aSpeakerSampleRestoresThePreviousPosition() async {
        controller.open(source(note), at: 10)

        #expect(controller.playRange(note, from: 30, to: 32))
        #expect(controller.state.isPlaying)
        #expect(controller.state.sample != nil)
        advance(2_200)
        #expect(!controller.state.isPlaying)
        #expect(controller.state.sample == nil)
        #expect(milliseconds == 10_000)
        #expect(await saves().allSatisfy { $0.position < 30 }, "a sample position is never saved")

        // While playing, the sample returns to the playing position and plays on.
        controller.play()
        advance(1_000)
        controller.playRange(note, from: 40, to: 41)
        advance(1_200)
        #expect(controller.state.isPlaying)
        #expect((11_000...11_400).contains(milliseconds), "back at about 11 s: \(milliseconds)")

        #expect(!controller.playRange(other, from: 0, to: 1), "another note")
    }

    // ports: PlaybackControllerTest#aPauseDuringASampleThatInterruptedPlaybackStaysPaused
    @Test func aPauseDuringASampleThatInterruptedPlaybackStaysPaused() async throws {
        controller.open(source(note), at: 10)

        // Unplugged headphones, another app taking the audio and the Pause button: each one restores the position and
        // stays paused.
        let interruptions: [(String, @MainActor () -> Void)] = [
            ("unplugged", { player.interrupt(.routeLost) }),
            ("interrupted", { player.interrupt(.interrupted) }),
            ("pause", { controller.pause() }),
        ]
        for (name, interrupt) in interruptions {
            controller.play()
            advance(1_000)
            // The player's position, not the last 150 ms tick.
            let before = player.position
            #expect(controller.playRange(note, from: 40, to: 45))
            advance(500)
            interrupt()
            try await waitFor("\(name): the sample ends") { controller.state.sample == nil }
            #expect(!controller.state.isPlaying, "\(name): paused")
            #expect(controller.state.position == before, "\(name): position from before")
            #expect(!player.holdsSession, "\(name): audio session given back")
            #expect(await saves().last == Save(note, before, final: true), "\(name): saved")
            advance(5_000)
            #expect(!controller.state.isPlaying, "\(name): still paused")
        }
    }

    // ports: PlaybackControllerTest#leavingDuringASampleSavesThePositionFromBefore
    @Test func leavingDuringASampleSavesThePositionFromBefore() async {
        controller.open(source(note), at: 5)
        controller.playRange(note, from: 20, to: 25)
        advance(1_000)
        controller.leave()
        #expect(await saves() == [Save(note, 5, final: true)])
    }

    // ports: PlaybackControllerTest#aReplacedDocumentIsPreparedAgainAtTheSamePosition
    @Test func aCompressedCopyIsOpenedAgainAtTheSamePosition() {
        controller.open(source(note), at: 0)
        controller.play()
        advance(3_000)

        let compressed = URL(fileURLWithPath: "/notes/audio.m4a")
        #expect(controller.reload(source(note, compressed)))
        #expect(player.loads == [audio, compressed])
        #expect(player.unloads == 1)
        #expect(Int((player.position * 1000).rounded()) == 3_000)
        #expect(controller.state.isPlaying, "still playing")
        #expect(controller.openSource?.url == compressed)
        advance(600)
        #expect(milliseconds == 3_600)
    }

    // ports: PlaybackControllerTest#aNoteLeftWhileItsFileIsPreparedAgainKeepsNoPlayer (the reload is synchronous: the
    // leave comes right after it)
    @Test func aNoteLeftRightAfterItsFileIsOpenedAgainKeepsNoPlayer() async {
        controller.open(source(note), at: 0)
        controller.play()
        advance(3_000)
        controller.reload(source(note, URL(fileURLWithPath: "/notes/audio.m4a")))

        controller.leave()
        #expect(player.loadedURL == nil, "the new file is let go of")
        #expect(controller.state == PlaybackState())
        #expect(!player.holdsSession)
        #expect(await saves().last == Save(note, 3, final: true))
        #expect(!controller.reload(source(note)), "nothing is open to reload")
    }

    // ports: PlaybackControllerTest#overlappingOpensOfTwoNotesKeepOnlyTheLastPlayer
    @Test func overlappingOpensOfTwoNotesKeepOnlyTheLastPlayer() async {
        let screenA = PlaybackOwner(), screenB = PlaybackOwner()
        let otherAudio = URL(fileURLWithPath: "/notes/other.m4a")
        #expect(controller.open(source(note), at: 0, owner: screenA))
        // The screen of A goes; then the screen of B opens.
        controller.leave(screenA)
        #expect(controller.open(source(other, otherAudio), at: 2, owner: screenB))
        #expect(controller.state.noteID == other)
        #expect(controller.state.position == 2)
        // The late leave of the cleared screen of A does not touch B.
        controller.leave(screenA)
        #expect(player.loadedURL == otherAudio)
        controller.play()
        #expect(controller.state.isPlaying)

        // Without a leave between them, the open that came last wins.
        #expect(controller.open(source(note), at: 0, owner: screenA))
        #expect(controller.open(source(other, otherAudio), at: 0, owner: screenB))
        #expect(player.loads == [audio, otherAudio, audio, otherAudio])
        #expect(player.unloads == 3)
        #expect(controller.state.noteID == other)
        #expect(await saves().map(\.noteID) == [note, other, note], "each note left is saved")
    }

    // ports: PlaybackControllerTest#aSecondScreenOfTheSameNoteKeepsItsPlayerAfterTheFirstLeaves
    @Test func aSecondScreenOfTheSameNoteKeepsItsPlayerAfterTheFirstLeaves() async {
        let first = PlaybackOwner(), second = PlaybackOwner()
        controller.open(source(note), at: 0, owner: first)
        controller.leave(first)
        #expect(controller.open(source(note), at: 4, owner: second))
        #expect(player.loads.count == 2)
        #expect(controller.state.position == 4)

        // The first screen's late leave leaves the second one playing.
        controller.play()
        controller.leave(first)
        #expect(player.loadedURL == audio)
        #expect(controller.state.isPlaying)
        #expect(controller.state.noteID == note)
        #expect(!controller.reload(source(note, URL(fileURLWithPath: "/notes/audio.m4a")), owner: first),
                "only the owner reloads")
        #expect(player.loads.count == 2)

        // The same note and file for a third screen keeps the player and moves it to that screen.
        let third = PlaybackOwner()
        #expect(controller.open(source(note), at: 0, owner: third))
        #expect(player.loads.count == 2)
        #expect(controller.state.isPlaying, "the player keeps playing")
        controller.leave(second)
        #expect(player.loadedURL == audio)
        controller.leave(third)
        #expect(player.loadedURL == nil)
        #expect(controller.state == PlaybackState())
        let last = await saves().last
        #expect(last?.noteID == note)
        #expect(last?.final == true)
    }

    // ports: PlaybackControllerTest#anOpenOfAnotherNoteDuringAReloadKeepsOnlyTheNewPlayer (the open comes right after
    // the reload)
    @Test func anOpenOfAnotherNoteAfterAReloadKeepsOnlyTheNewPlayer() async {
        controller.open(source(note), at: 0)
        controller.play()
        advance(3_000)
        controller.reload(source(note, URL(fileURLWithPath: "/notes/audio.m4a")))
        #expect(controller.open(source(other), at: 0))

        #expect(player.loads.count == 3)
        #expect(player.unloads == 2)
        #expect(controller.state.noteID == other)
        #expect(!player.holdsSession, "the first note's audio session is given back")
        #expect(await saves().last == Save(note, 3, final: true), "the position of the first note is saved")
    }

    // ports: PlaybackControllerTest#aFileThatCannotBePlayedFails
    @Test func aFileThatCannotBePlayedFails() {
        let broken = URL(fileURLWithPath: "/notes/broken.m4a")
        player.unplayable = [broken]
        #expect(!controller.open(source(note, broken), at: 0))
        #expect(controller.state.status == .failed)
        #expect(controller.state.noteID == note)
        #expect(player.loadedURL == nil)
        controller.play()
        #expect(!player.holdsSession)
        #expect(!controller.state.isPlaying)

        // A replaced file opens again.
        player.unplayable = []
        #expect(controller.open(source(note, broken), at: 0))
        #expect(controller.state.status == .paused)
    }

    // MARK: iOS

    @Test func aFinalSaveNeverLandsBeforeTheFiveSecondSaveAskedForEarlier() async {
        controller.open(source(note), at: 0)
        controller.play()
        positions.hold()
        advance(5_100)
        controller.pause()
        let settled = Task { await controller.settle() }
        await Task.yield()
        #expect(positions.saves.isEmpty, "the 5 s save is still writing")
        positions.release()
        await settled.value
        #expect(positions.saves == [Save(note, 5.1, final: false), Save(note, 5.1, final: true)])
    }


    @Test func theEndOfTheFilePausesThereAndSavesTheDuration() async {
        controller.open(source(note), at: 58)
        controller.play()
        advance(2_500)
        #expect(!controller.state.isPlaying)
        #expect(!ticker.isRunning)
        #expect(!player.holdsSession)
        #expect(await saves().last == Save(note, 60, final: true))

        // Play at the end starts again.
        controller.play()
        #expect(controller.state.isPlaying)
        #expect(controller.state.position == 0)
    }

    @Test func skipsAreTenSecondsClampedToTheFileAndDropASample() {
        controller.open(source(note), at: 5)
        controller.skip(by: -PlaybackSkip.interval)
        #expect(controller.state.position == 0)
        controller.skip(by: PlaybackSkip.interval)
        #expect(controller.state.position == 10)
        controller.seek(to: 55)
        controller.skip(by: PlaybackSkip.interval)
        #expect(controller.state.position == 60)

        controller.seek(to: 10)
        controller.playRange(note, from: 30, to: 40)
        controller.skip(by: PlaybackSkip.interval)
        #expect(controller.state.sample == nil, "a skip is a seek: the sample is dropped")
        #expect(controller.state.position == 40)
        advance(2_000)
        #expect(controller.state.isPlaying, "playback goes on from there")
    }

    @Test func aNestedSampleKeepsTheFirstRestorePoint() async {
        controller.open(source(note), at: 7)
        controller.playRange(note, from: 20, to: 25)
        advance(1_000)
        controller.playRange(note, from: 30, to: 31)
        #expect(controller.state.sample?.restorePosition == 7)
        advance(1_200)
        #expect(controller.state.sample == nil)
        #expect(controller.state.position == 7)
        #expect(!controller.state.isPlaying)
        #expect(await saves().isEmpty, "a sample that ends by itself saves nothing")
    }

    @Test func goingToTheBackgroundSavesWithoutPausing() async {
        controller.open(source(note), at: 3)
        controller.play()
        advance(1_000)
        controller.savePosition()
        #expect(await saves() == [Save(note, 4, final: true)])
        #expect(controller.state.isPlaying)

        // During a sample the position from before is what counts.
        controller.playRange(note, from: 40, to: 45)
        controller.savePosition()
        #expect(await saves().last == Save(note, 4, final: true))
    }

    @Test func aRecordingClosesThePlayerAndNothingOpensUntilItEnds() async {
        controller.open(source(note), at: 2)
        controller.play()
        controller.setBlocked(true)
        #expect(controller.state == PlaybackState())
        #expect(player.loadedURL == nil)
        #expect(await saves() == [Save(note, 2, final: true)])
        #expect(!controller.open(source(note), at: 2))
        controller.setBlocked(false)
        #expect(controller.open(source(note), at: 2))
    }

    @Test func theLockScreenControlsPlayPauseSkipAndSeek() async throws {
        controller.open(source(note), at: 20)
        player.send(.remotePlay)
        try await waitFor("play") { controller.state.isPlaying }
        player.send(.remoteSkip(-PlaybackSkip.interval))
        try await waitFor("skip") { controller.state.position == 10 }
        player.send(.remoteSeek(42))
        try await waitFor("seek") { controller.state.position == 42 }
        player.send(.remotePause)
        try await waitFor("pause") { !controller.state.isPlaying }
        #expect(await saves().last == Save(note, 42, final: true))
    }

    @Test func theSpeedStaysForTheNextFile() {
        controller.rate = 1.5
        controller.open(source(note), at: 0)
        #expect(player.rate == 1.5)
        controller.open(source(other), at: 0)
        #expect(controller.state.rate == 1.5)
        #expect(player.rate == 1.5)
    }
}
