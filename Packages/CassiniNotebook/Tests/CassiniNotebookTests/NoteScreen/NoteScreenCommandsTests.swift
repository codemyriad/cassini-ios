import Foundation
import Testing
@testable import CassiniNotebook

/// What the Note screen's menu rows, its effects' sheets and its scroll do (the rules `NoteScreenModel` carries out).
@Suite struct NoteScreenCommandsTests {
    typealias F = TranscriptFixtures

    private func job(_ state: JobState, _ kind: JobKind = .transcribe, for note: Note) -> Job {
        Job(noteID: note.id, seq: 1, kind: kind, state: state, enqueuedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func menuRowsBecomeEffects() {
        var screen = NoteScreenState()
        let note = F.weeklySync
        let rows: [(NoteMenuAction, NoteEffect)] = [
            (.toggleStar, .toggleStar), (.rename, .rename), (.documentInfo, .documentInfo),
            (.exportTranscript(.webVTT), .exportTranscript(.webVTT)), (.exportDocument, .exportDocument),
            (.shareAudio, .shareAudio), (.transcribe, .transcribe(.transcribe)), (.transcribeAgain, .transcribe(.transcribeAgain)),
            (.stop, .stop), (.removeFromQueue, .removeFromQueue), (.moveToTrash, .moveToTrash),
            (.speakers, .openSpeakers), (.versions, .openVersions),
        ]
        for (row, effect) in rows { #expect(screen.menu(row, note: note, job: nil, readOnly: nil) == effect, "\(row)") }
        #expect(screen.dialog == nil)
    }

    /// Resume goes on with the job's kind; Start over asks first.
    @Test func resumeKeepsTheJobsKindAndStartOverAsks() {
        var screen = NoteScreenState()
        let note = F.weeklySync
        let paused = job(.paused, .speakersOnly, for: note)
        #expect(screen.menu(.resume, note: note, job: paused, readOnly: nil) == .transcribe(.speakersOnly))
        #expect(screen.menu(.resume, note: note, job: nil, readOnly: nil) == .transcribe(.transcribe))
        #expect(screen.menu(.startOver, note: note, job: paused, readOnly: nil) == nil)
        #expect(screen.dialog == .startOver)
        #expect(screen.confirmDialog() == .startOver)
    }

    /// Speakers and Transcript versions follow the read-only gate as their chips do.
    @Test func theSpeakerRowsFollowTheReadOnlyGate() {
        var screen = NoteScreenState()
        #expect(screen.menu(.speakers, note: F.weeklySync, job: nil, readOnly: .jobPending) == nil)
        #expect(screen.dialog == .readOnly(.jobPending))
        screen.dismissDialog()
        #expect(screen.menu(.versions, note: F.weeklySync, job: nil, readOnly: .jobPending) == nil)
        #expect(screen.dialog == .readOnly(.jobPending))
    }

    @Test func effectsOpenTheirSheets() throws {
        let note = F.weeklySync
        let segment = try #require(note.transcript.first)
        #expect(NoteSheet(opening: .nameSpeaker("a"), in: note) == .naming("a", draft: nil))
        #expect(NoteSheet(opening: .openVersions, in: note) == .versions)
        #expect(NoteSheet(opening: .openSpeakers, in: note) == .speakers)
        #expect(NoteSheet(opening: .rename, in: note) == .rename(draft: nil))
        #expect(NoteSheet(opening: .documentInfo, in: note) == .documentInfo)
        #expect(NoteSheet(opening: .editPassage(segment.id), in: note) == .editing(segment))
        #expect(NoteSheet(opening: .editPassage(UUID()), in: note) == nil, "a passage that is gone opens nothing")
        #expect(NoteSheet(opening: .seekAndPlay(3), in: note) == nil)
        #expect(NoteSheet(opening: .exportDocument, in: note) == nil)
    }

    @Test func aSheetKeptWithTheSceneOpensAgainAsItWas() throws {
        let note = F.weeklySync
        let segment = try #require(note.transcript.first)
        for sheet in [NoteSheet.rename(draft: "Ret"), .speakers, .versions, .documentInfo, .naming("a", draft: "An"), .editing(segment)] {
            #expect(NoteSheet(sheet.overlay, draft: sheet.draft, in: note) == sheet)
        }
    }

    /// A drag during playback pauses following and stops the resume timer; coming to rest starts it; a drag while
    /// paused changes nothing.
    @Test func theScrollPausesFollowingAndRestartsTheResumeTimer() {
        var follow = PlaybackFollow()
        #expect(follow.scrolled(.idle, playing: true) == .keep, "following: nothing to resume")
        #expect(follow.scrolled(.dragging, playing: false) == .cancel)
        #expect(follow.following, "a drag while paused leaves following on")
        #expect(follow.scrolled(.dragging, playing: true) == .cancel)
        #expect(!follow.following)
        #expect(follow.scrolled(.moving, playing: true) == .keep)
        #expect(follow.scrolled(.idle, playing: true) == .restart(PlaybackFollow.resumeAfter))
    }

    @Test func aMatchInViewIsNotScrolledTo() {
        #expect(PlaybackFollow.isInView(lineY: 0, lineHeight: 24, height: 600))
        #expect(PlaybackFollow.isInView(lineY: 576, lineHeight: 24, height: 600))
        #expect(!PlaybackFollow.isInView(lineY: 577, lineHeight: 24, height: 600))
        #expect(!PlaybackFollow.isInView(lineY: -1, lineHeight: 24, height: 600))
        #expect(!PlaybackFollow.isInView(lineY: 10, lineHeight: 24, height: 0), "before the pane is laid out")
    }
}
