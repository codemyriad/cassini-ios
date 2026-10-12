import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// The Note screen's rules over the note and its job (Android `NoteViewModelTest`, without the stores: the app's
/// hosted and UI tests cover the wiring).
@Suite struct NoteScreenTests {
    typealias F = TranscriptFixtures

    private func job(_ state: JobState, _ kind: JobKind = .transcribe, doneMs: Int64 = 0, totalMs: Int64? = 4_000,
                     failure: JobFailure? = nil, pause: PauseReason? = nil, for note: Note) -> Job {
        Job(noteID: note.id, seq: 1, kind: kind, state: state, pauseReason: pause, failure: failure, doneMs: doneMs,
            totalMs: totalMs, enqueuedAt: Date(timeIntervalSince1970: 0))
    }

    private func document(_ state: DocumentState, acknowledged: Bool = false) -> Note {
        var note = F.weeklySync
        note.origin = .importedDocument
        note.document = DocumentInfo(state: state, trustAcknowledged: acknowledged)
        return note
    }

    // ports: NoteViewModelTest#theModeFollowsTheJobAndTheDocument
    @Test func theModeFollowsTheJobAndTheDocument() {
        let note = F.weeklySync
        #expect(NoteMode.of(note, job: nil) == .reading)
        let queued = NoteMode.of(note, job: job(.queued, .transcribeAgain, for: note), ahead: 2)
        #expect(queued == .queued(ahead: 2, overDocument: true))
        #expect(queued.showsReading && !queued.showsDraft, "the transcript stays under the Queued card")
        #expect(NoteSubtitle.of(note, mode: queued, now: note.createdAt, calendar: .current) != nil)

        let running = NoteMode.of(note, job: job(.running, for: note))
        #expect(running == .processing)
        #expect(running.showsDraft, "the draft replaces the transcript")
        #expect(!running.hasPlayer, "Transcribing has no player")
        #expect(!running.showsReading, "no chips")

        let paused = NoteMode.of(note, job: job(.paused, doneMs: 400, for: note))
        #expect(paused == .paused(doneMs: 400, totalMs: 4_000, hasCheckpoint: true))
        #expect(paused.showsDraft && paused.hasPlayer, "paused has the read-only draft and the player")
        let banners = NoteBanners.of(note, job: job(.paused, doneMs: 400, for: note), mode: paused, facts: .init())
        #expect(banners.map(\.kind) == [.paused])
        #expect(banners[0].doneMs == 400 && banners[0].totalMs == 4_000)

        #expect(NoteMode.of(note, job: job(.failed, for: note)) == .failed(overDocument: true))
        #expect(NoteMode.of(note, job: job(.needsConsent, for: note)) == .reading)
        var plain = note
        plain.transcript = []; plain.status = .audioOnly
        #expect(NoteMode.of(plain, job: job(.failed, for: plain)) == .failed(overDocument: false))
        #expect(NoteMode.failed(overDocument: false).showsDraft, "a failure without a transcript shows the draft so far")
        #expect(NoteSubtitle.of(note, mode: .reading, now: note.createdAt, calendar: .current) == nil,
                "reading mode has no subtitle")
    }

    // ports: NoteViewModelTest#aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer
    @Test func aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer() {
        var plain = F.weeklySync
        plain.transcript = []; plain.status = .audioOnly; plain.speakers = nil
        #expect(NoteMode.of(plain, job: nil) == .audioOnly)
        #expect(NoteBanners.of(plain, job: nil, mode: .audioOnly, facts: .init()).map(\.kind) == [.plainAudio])
        #expect(NoteBanners.of(plain, job: nil, mode: .audioOnly, facts: .init())[0].actions == [.transcribe])
        #expect(NoteTranscripts.sealed(plain).isEmpty)

        var unplayable = plain
        unplayable.audio = .unplayable(.interrupted)
        let mode = NoteMode.of(unplayable, job: nil)
        #expect(mode == .unplayable)
        #expect(!mode.hasPlayer)
        #expect(NoteBanners.of(unplayable, job: nil, mode: mode, facts: .init()).map(\.kind) == [.unplayable])
        #expect(TranscribeRow.of(unplayable, job: nil) == nil, "nothing to transcribe")
    }

    /// iOS: a note being recorded, or too long to transcribe, says so without offering Transcribe.
    @Test func plainAudioOffersTranscribeOnlyWhenItCanBeTranscribed() {
        var recording = F.weeklySync
        recording.transcript = []; recording.status = .recording; recording.audio = .live
        #expect(NoteBanners.of(recording, job: nil, mode: .audioOnly, facts: .init())[0].actions.isEmpty)
        var long = recording
        long.audio = .plain; long.status = .audioOnly; long.duration = Limits.maxTranscribeDuration + 1
        let banner = NoteBanners.of(long, job: nil, mode: .audioOnly, facts: .init())[0]
        #expect(banner.tooLong && banner.actions.isEmpty)
    }

    // ports: NoteViewModelTest#aJobRowMakesTheSealedTranscriptReadOnly
    @Test func aJobRowMakesTheSealedTranscriptReadOnly() {
        let note = F.weeklySync
        let queued = job(.queued, .transcribeAgain, for: note)
        let reason = ReadOnlyReason.of(note, job: queued)
        #expect(reason == .jobPending)
        var screen = NoteScreenState()
        #expect(screen.speakerTapped("b", readOnly: reason) == nil, "no Name sheet")
        #expect(screen.dialog == .readOnly(.jobPending))
        screen.dismissDialog()
        #expect(screen.versionsTapped(readOnly: reason) == nil)
        #expect(screen.dialog == .readOnly(.jobPending))
        screen.dismissDialog()
        #expect(screen.editPassage(note.transcript[0].id, readOnly: reason) == nil)
        #expect(screen.dialog == .readOnly(.jobPending))
        screen.dismissDialog()
        #expect(screen.speakersTapped(readOnly: reason) == nil)
        #expect(screen.dialog == .readOnly(.jobPending))
        #expect(screen.confirmDialog() == nil, "the notice only closes")
        #expect(TranscribeRow.of(note, job: queued) == .removeFromQueue, "no Transcribe again while queued")

        #expect(ReadOnlyReason.of(note, job: job(.needsConsent, for: note)) == nil, "waiting for consent is no job")
        #expect(screen.speakerTapped("b", readOnly: nil) == .nameSpeaker("b"))
        #expect(screen.versionsTapped(readOnly: nil) == .openVersions)
        #expect(screen.speakersTapped(readOnly: nil) == .openSpeakers)
        #expect(screen.editPassage(note.transcript[0].id, readOnly: nil) == .editPassage(note.transcript[0].id))
    }

    // ports: NoteViewModelTest#aDocumentThatIsNotOkCannotBeRenamedAndTranscribesFresh
    @Test func aDocumentThatIsNotOkCannotBeRenamedAndTranscribesFresh() {
        let note = document(.staleAudio)
        #expect(ReadOnlyReason.of(note, job: nil) == .trust)
        let banners = NoteBanners.of(note, job: nil, mode: .reading, facts: .init())
        #expect(banners.map(\.kind) == [.trustAudioChanged])
        var screen = NoteScreenState()
        #expect(screen.speakerTapped("a", readOnly: .trust) == nil)
        #expect(screen.dialog == .readOnly(.trust))
        screen.dismissDialog()
        #expect(screen.bannerAction(.transcribeAgain, note: note, job: nil) == nil)
        #expect(screen.dialog == .transcribeFresh)
        #expect(screen.confirmDialog() == .transcribe(.transcribeAgain))
        #expect(screen.dialog == nil)
    }

    // ports: NoteViewModelTest#theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges
    @Test func theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges() {
        let verified = document(.ok)
        var screen = NoteScreenState()
        func banners(_ note: Note) -> [NoteBanner.Kind] {
            NoteBanners.of(note, job: nil, mode: .reading, facts: .init(trustToggled: screen.trustToggled)).map(\.kind)
        }
        #expect(banners(verified).isEmpty)
        screen.toggleTrust()
        #expect(banners(verified) == [.trustVerified])
        screen.toggleTrust()
        #expect(banners(verified).isEmpty)

        let unverified = document(.unverified)
        #expect(banners(unverified) == [.trustNotVerified])
        #expect(NoteChips.of(unverified)?.trust == .notVerified)
        #expect(screen.bannerAction(.playAnyway, note: unverified, job: nil) == .acknowledgeTrustAndPlay)
        #expect(banners(document(.unverified, acknowledged: true)).isEmpty, "acknowledged: the banner stays hidden")
    }

    // ports: NoteViewModelTest#aWordTapSeeksAndPlaysAndFollowModeResumes
    @Test func aWordTapSeeksAndPlaysAndFollowModeResumes() {
        let transcript = NoteTranscripts.sealed(F.weeklySync)
        var screen = NoteScreenState()
        screen.follow.dragged(playing: true)
        #expect(!screen.follow.following)
        #expect(screen.wordTapped(WordRef(turnID: "w3", index: 0), in: transcript) == .seekAndPlay(2))
        #expect(screen.follow.following)
        #expect(screen.playTurn("w4", in: transcript) == .seekAndPlay(3))
        #expect(screen.wordTapped(WordRef(turnID: "w9", index: 0), in: transcript) == nil)
    }

    // ports: NoteViewModelTest#theActiveWordFollowsThePlayerPosition
    /// The screen asks the index only while its own player is open (`PlaybackStore.owns`), so another note's player
    /// marks nothing; the hosted tests check that part.
    @Test func theActiveWordFollowsThePlayerPosition() {
        let transcript = NoteTranscripts.sealed(F.weeklySync)
        #expect(transcript.activeWord(at: 0) == WordRef(turnID: "w0", index: 0))
        #expect(transcript.activeWord(at: 1.1) == WordRef(turnID: "w2", index: 0))
        #expect(transcript.activeWord(at: 2.5) == WordRef(turnID: "w3", index: 0),
                "between words the last started word stays active")
    }

    // ports: NoteViewModelTest#searchFromTheLibraryIsPrefilledAndStepsThroughMatches
    @Test func searchFromTheLibraryIsPrefilledAndStepsThroughMatches() {
        let note = F.note([.init("a", 0, 400, "Giovedì"), .init("b", 1_000, 1_400, "Buongiorno"),
                           .init("c", 2_000, 2_300, "Eccomi"), .init("a", 3_000, 3_500, "giovedi")])
        let turns = NoteTranscripts.sealed(note).turns
        var screen = NoteScreenState(query: " giovedi ")
        #expect(screen.search?.query == "giovedi")
        let matches = TranscriptSearch.matches(turns, query: screen.search!.query)
        #expect(matches.map(\.turnID) == ["w0", "w3"], "giovedì and giovedi")
        #expect(screen.search?.current == 0)
        screen.search?.next(of: matches.count)
        #expect(screen.search?.current == 1)
        screen.search?.next(of: matches.count)
        #expect(screen.search?.current == 0, "it wraps around")
        screen.search?.previous(of: matches.count)
        #expect(screen.search?.current == 1)
        screen.search?.setQuery("BUONGIORNO")
        #expect(TranscriptSearch.matches(turns, query: screen.search!.query).map(\.turnID) == ["w1"])
        #expect(TranscriptSearch.matches(turns, query: "domani").isEmpty)
        screen.closeSearch()
        #expect(screen.search == nil)
        #expect(NoteScreenState(query: "  ").search == nil, "a blank query opens no search")
    }

    // ports: NoteViewModelTest#aDocumentWithNoWordsSaysSoOnlyWhenItsTranscriptHasLoaded
    /// iOS reads the transcript with the note, so "loaded" is always true: only an unreadable transcript is left out.
    @Test func aDocumentWithNoWordsSaysSoOnlyWhenItsTranscriptCanBeRead() {
        #expect(!F.weeklySync.saysNoSpeech(in: .reading), "a document with words")
        var empty = document(.ok)
        empty.transcript = []
        #expect(NoteMode.of(empty, job: nil) == .reading)
        #expect(empty.saysNoSpeech(in: .reading), "a document with no words")
        var unreadable = document(.unreadable)
        unreadable.transcript = []
        #expect(!unreadable.saysNoSpeech(in: .reading), "a transcript that cannot be read")
        #expect(!empty.saysNoSpeech(in: .processing), "not for a draft")
        var transcribed = F.weeklySync
        transcribed.transcript = []
        #expect(transcribed.saysNoSpeech(in: NoteMode.of(transcribed, job: nil)), "a recording transcribed to no words")
    }

    // ports: NoteViewModelTest#aNoteTrashedElsewhereClosesTheScreen
    @Test func aNoteTrashedElsewhereClosesTheScreen() {
        var note = F.weeklySync
        #expect(!NoteScreenState.isGone(note))
        note.trashedAt = Date(timeIntervalSince1970: 9)
        #expect(NoteScreenState.isGone(note))
        #expect(NoteScreenState.isGone(nil), "deleted for good")
    }

    // ports: NoteViewModelTest#pausedRowsResumeOrStartOverWithConfirmation
    @Test func pausedRowsResumeOrStartOverWithConfirmation() {
        let note = F.weeklySync
        let paused = job(.paused, .transcribeAgain, doneMs: 1_000, for: note)
        #expect(TranscribeRow.of(note, job: paused) == .resumeOrStartOver)
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.resume, note: note, job: paused) == .transcribe(.transcribeAgain))
        #expect(screen.bannerAction(.startOver, note: note, job: paused) == nil)
        #expect(screen.dialog == .startOver)
        #expect(screen.confirmDialog() == .startOver)
        #expect(TranscribeRow.of(note, job: job(.queued, for: note)) == .removeFromQueue)
        #expect(TranscribeRow.of(note, job: job(.running, for: note)) == .stop)
    }

    // ports: NoteViewModelTest#anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears
    @Test func anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears() {
        let note = document(.unverified)
        let failed = job(.failed, .transcribeAgain, failure: .documentRefused(.unverified), for: note)
        #expect(TranscribeRow.of(note, job: failed) == .transcribeAgainUnavailable)
        var screen = NoteScreenState()
        #expect(screen.transcribeAgain(note) == nil)
        #expect(screen.dialog == nil, "nothing to confirm either")
        let banner = NoteBanners.of(note, job: failed, mode: .failed(overDocument: true), facts: .init())
            .first { $0.kind == .failed }!
        #expect(banner.failure == .documentRefused(.unverified))
        #expect(banner.actions.isEmpty, "no Try again: it fails the same way")
        #expect(screen.dismiss(banner, note: note, job: failed) == .clearFailed)
        #expect(screen.dismissed.isEmpty)
    }

    /// Every banner can be dismissed by its id; a failure with saved progress offers Try again and Start over.
    @Test func bannersAreDismissedByIdAndFollowTheirOrder() {
        let note = F.weeklySync
        var screen = NoteScreenState()
        let failed = job(.failed, doneMs: 1_000, failure: .save, for: note)
        let mode = NoteMode.of(note, job: failed)
        let banner = NoteBanners.of(note, job: failed, mode: mode, facts: .init())[0]
        #expect(banner.kind == .failed && banner.actions == [.tryAgain, .startOver])
        #expect(screen.dismiss(banner, note: note, job: failed) == nil)
        #expect(NoteBanners.of(note, job: failed, mode: mode, facts: .init(dismissed: screen.dismissed)).isEmpty)

        let paused = job(.paused, doneMs: 0, pause: .system, for: note)
        let held = NoteBanners.of(note, job: paused, mode: NoteMode.of(note, job: paused),
                                  facts: .init(queueHold: .user, waitingJobs: 2))
        #expect(held.map(\.kind) == [.pausedEarly, .queueHeld])
        #expect(held[0].bySystem && held[1].count == 2)
        #expect(screen.bannerAction(.continueQueue, note: note, job: paused) == .continueQueue)

        let mismatch = job(.failed, failure: .checkpointMismatch, for: note)
        #expect(NoteBanners.of(note, job: mismatch, mode: NoteMode.of(note, job: mismatch), facts: .init())
            .map(\.kind) == [.checkpointMismatch])
        let memory = job(.paused, doneMs: 10, pause: .memory, for: note)
        #expect(NoteBanners.of(note, job: memory, mode: NoteMode.of(note, job: memory), facts: .init()).map(\.kind) == [.memory])
    }

    /// iOS: one voice comes from the speaker step's failure, and only without a job.
    @Test func oneVoiceAndNoSpeakersComeFromTheSpeakerStep() {
        var note = F.weeklySync
        note.speakerAnalysisFailure = .speakers
        #expect(NoteBanners.of(note, job: nil, mode: .reading, facts: .init()).map(\.kind) == [.oneVoice])
        #expect(NoteBanners.of(note, job: job(.queued, for: note), mode: .queued(ahead: 0, overDocument: true),
                               facts: .init()).isEmpty)
        note.speakerAnalysisFailure = .empty
        #expect(NoteBanners.of(note, job: nil, mode: .reading, facts: .init()).map(\.kind) == [.noSpeakers])
        #expect(NoteBanners.of(F.weeklySync, job: nil, mode: .reading, facts: .init(playbackFailed: true)).map(\.kind)
            == [.playbackFailed])
    }

    /// The chips: trust for a document, the version chip from two versions on, and the speakers.
    @Test func theChipsShowTrustVersionAndSpeakers() {
        var note = F.weeklySync
        #expect(NoteChips.of(note) == NoteChips(trust: nil, version: nil, speakers: 3))
        note.saveCurrentVersion(name: "Speaker analysis")
        #expect(NoteChips.of(note)?.version == nil, "one version: no chip")
        note.mergeSpeaker("b", into: "a", stamp: VersionStamp(date: Date(timeIntervalSince1970: 1)))
        let chip = NoteChips.of(note)?.version
        #expect(chip == VersionChip(index: 2, count: 2, kind: .merged))
        #expect(NoteChips.of(note)?.speakers == 2)
        note.selectVersion(note.versions![0].id)
        #expect(NoteChips.of(note)?.version == VersionChip(index: 1, count: 2, kind: .original))
        var plain = note
        plain.transcript = []; plain.status = .audioOnly
        #expect(NoteChips.of(plain) == nil)
    }

    @Test func theSubtitleNamesTodayAndYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let note = F.weeklySync
        let today = NoteSubtitle.of(note, mode: .audioOnly, now: note.createdAt.addingTimeInterval(60), calendar: calendar)
        #expect(today?.day == .today)
        #expect(today?.duration == 3.9)
        let yesterday = NoteSubtitle.of(note, mode: .audioOnly, now: note.createdAt.addingTimeInterval(86_400), calendar: calendar)
        #expect(yesterday?.day == .yesterday)
        let later = NoteSubtitle.of(note, mode: .audioOnly, now: note.createdAt.addingTimeInterval(5 * 86_400), calendar: calendar)
        #expect(later?.day == .date(calendar.startOfDay(for: note.createdAt)))
    }
}

@Suite struct PlaybackFollowTests {
    // ports: ScreenBehaviourTest#aDragWithPlaybackPausedLeavesFollowingOn
    @Test func aDragWithPlaybackPausedLeavesFollowingOn() {
        var follow = PlaybackFollow()
        follow.dragged(playing: false)
        #expect(follow.following)
        #expect(!follow.showsChip(playing: false))
    }

    // ports: ScreenBehaviourTest#aDragDuringPlaybackPausesFollowingAndShowsTheChip
    @Test func aDragDuringPlaybackPausesFollowingAndShowsTheChip() {
        var follow = PlaybackFollow()
        follow.dragged(playing: true)
        #expect(!follow.following)
        #expect(follow.showsChip(playing: true))
        #expect(!follow.showsChip(playing: false), "the chip shows only while the note plays")
        follow.resume()
        #expect(follow.following && !follow.showsChip(playing: true))
        #expect(PlaybackFollow.resumeAfter == .seconds(4))
    }

    @Test func theActiveLineScrollsToThirtyPercentOnceItLeavesTheTopSeventy() {
        #expect(PlaybackFollow.scroll(lineY: 100, height: 1000) == nil)
        #expect(PlaybackFollow.scroll(lineY: 700, height: 1000) == nil)
        #expect(PlaybackFollow.scroll(lineY: 701, height: 1000) == 401)
        #expect(PlaybackFollow.scroll(lineY: -50, height: 1000) == -350)
        #expect(PlaybackFollow.scroll(lineY: 10, height: 0) == nil)
    }
}

@Suite struct PassageEditTests {
    typealias F = TranscriptFixtures

    @Test func aRevisedTextDropsItsWordTimesAndTakesTheSpeakersLabel() {
        let note = F.weeklySync
        let original = note.transcript[0]
        let same = original.revised(text: " \(original.text) ", speakerID: "c", speakers: note.speakers!)
        #expect(same.words == original.words, "the text did not change")
        #expect(same.speakerID == "c" && same.speaker == "Paolo Ferri")
        let edited = original.revised(text: "Ciao a tutti voi.", speakerID: nil, speakers: note.speakers!)
        #expect(edited.text == "Ciao a tutti voi." && edited.words.isEmpty)
        #expect(edited.speakerID == nil && edited.speaker == nil)
        #expect(!TranscriptSegment.isSavable("  \n"))
    }

    @Test func savingReportsAPassageThatChangedMeanwhileAndKeepsTheVersionBefore() {
        var note = F.weeklySync
        let original = note.transcript[0]
        let edited = original.revised(text: "Salve.", speakerID: "a", speakers: note.speakers!)
        let stamp = VersionStamp(date: Date(timeIntervalSince1970: 5))
        #expect(note.revisePassage(original, to: original, stamp: stamp) == .unchanged)
        #expect(note.revisePassage(original, to: edited, stamp: stamp) == .saved)
        #expect(note.transcript[0] == edited)
        #expect(note.versions?.count == 1 && note.versions?[0].name == Note.beforePassageEditName)
        #expect(note.versions?[0].segments[0] == original)
        #expect(note.selectedVersionID == nil)
        #expect(note.revisePassage(original, to: edited, stamp: stamp) == .changed, "the passage is gone")
        #expect(!note.holds(original) && note.holds(edited))
    }
}

@Suite struct DocumentInfoFactsTests {
    typealias F = TranscriptFixtures

    // ports: NoteMappingTest#documentInfoNamesTheSpeechModel
    /// iOS names Apple's on-device model; an engine this app does not know shows as it is.
    @Test func documentInfoNamesTheSpeechModel() {
        #expect(DocumentInfoFacts.modelName(TranscriptProvenance.appleSpeech) == "Apple SpeechTranscriber")
        #expect(DocumentInfoFacts.modelName("whisper-large") == "whisper-large", "a model this app does not know")
        #expect(DocumentInfoFacts.modelName("apple-speechtranscriber-2") == "apple-speechtranscriber-2")
    }

    // ports: NoteViewModelTest#documentInfoReadsTheDocumentFactsWhenOpened
    @Test func documentInfoReadsTheFactsOfTheNoteAndItsRun() {
        var note = F.weeklySync
        note.duration = 40
        note.speakers?[0].match = .confirmed(voice: UUID(), score: 0.9)
        let provenance = TranscriptProvenance(language: "it-IT", inferenceMs: 4_000, resumedFromMs: 0,
                                              speakerDiarization: .init(model: "m", sha: nil, turnCount: 4, speakerCount: 3))
        let info = DocumentInfoFacts.of(note, provenance: provenance, fileBytes: 1_234)
        #expect(info.fileBytes == 1_234)
        #expect(info.model == "Apple SpeechTranscriber")
        #expect(info.speakers == 3)
        #expect(info.realtimeFactor == 10)
        #expect(info.speakersToldApart == true)
        #expect(info.namesFromVoices == 1)
        #expect(info.resumedFromMs == nil)
        #expect(info.language == "it-IT")
        let bare = DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil)
        #expect(bare.model == nil && bare.realtimeFactor == nil && bare.speakersToldApart == nil)
    }
}
