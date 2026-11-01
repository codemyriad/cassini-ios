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

    /// The reading content comes below a Queued card or a failure banner, chips first (Android `NoteModeBody`).
    @Test func theReadingContentComesBelowTheCardOrTheFailureBanner() {
        #expect(NoteMode.reading.sections == [.chips, .banners])
        #expect(NoteMode.queued(ahead: 0, overDocument: true).sections == [.card, .chips, .banners])
        #expect(NoteMode.queued(ahead: 0, overDocument: false).sections == [.card, .banners])
        #expect(NoteMode.processing.sections == [.card, .banners])
        #expect(NoteMode.failed(overDocument: true).sections == [.banners, .chips])
        #expect(NoteMode.failed(overDocument: false).sections == [.banners])
        #expect(NoteMode.audioOnly.sections == [.banners])
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

        #expect(NoteMode.of(note, job: job(.failed, for: note)) == .failed(overDocument: true))
        #expect(NoteMode.of(note, job: job(.needsConsent, for: note)) == .reading)
        var plain = note
        plain.transcript = []; plain.status = .audioOnly
        #expect(NoteMode.of(plain, job: job(.failed, for: plain)) == .failed(overDocument: false))
        #expect(NoteMode.failed(overDocument: false).showsDraft, "a failure without a transcript shows the draft so far")
        #expect(NoteSubtitle.of(note, mode: .reading, now: note.createdAt, calendar: .current) == nil,
                "reading mode has no subtitle")
    }

    // ports: NoteViewModelTest#aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer (its modes; the banners are
    // CassiniEngine's NoteBannersTests)
    @Test func aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer() {
        var plain = F.weeklySync
        plain.transcript = []; plain.status = .audioOnly; plain.speakers = nil
        #expect(NoteMode.of(plain, job: nil) == .audioOnly)
        #expect(NoteTranscripts.sealed(plain).isEmpty)

        var unplayable = plain
        unplayable.audio = .unplayable(.interrupted)
        let mode = NoteMode.of(unplayable, job: nil)
        #expect(mode == .unplayable)
        #expect(!mode.hasPlayer)
        #expect(TranscribeRow.of(unplayable, job: nil) == nil, "nothing to transcribe")
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

    // ports: NoteViewModelTest#aDocumentThatIsNotOkCannotBeRenamedAndTranscribesFresh (its banner is in NoteBannersTests)
    @Test func aDocumentThatIsNotOkCannotBeRenamedAndTranscribesFresh() {
        let note = document(.staleAudio)
        #expect(ReadOnlyReason.of(note, job: nil) == .trust)
        var screen = NoteScreenState()
        #expect(screen.speakerTapped("a", readOnly: .trust) == nil)
        #expect(screen.dialog == .readOnly(.trust))
        screen.dismissDialog()
        #expect(screen.bannerAction(.transcribeAgain, note: note, job: nil) == nil)
        #expect(screen.dialog == .transcribeFresh)
        #expect(screen.confirmDialog() == .transcribe(.transcribeAgain))
        #expect(screen.dialog == nil)
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

    // ports: NoteViewModelTest#pausedRowsResumeOrStartOverWithConfirmation (its banner is in NoteBannersTests)
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

    /// The chips: trust for a document, the version chip from two versions on, and the speakers.
    @Test func theChipsShowTrustVersionAndSpeakers() {
        var note = F.weeklySync
        #expect(NoteChips.of(note) == NoteChips(trust: nil, version: nil, speakers: 3))
        note.saveCurrentVersion(.speakerAnalysis)
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
        #expect(later?.day == DayGroups.key(note.createdAt, now: note.createdAt.addingTimeInterval(5 * 86_400), calendar: calendar))
        guard case .date(_, let withYear)? = later?.day else { Issue.record("not a date"); return }
        #expect(!withYear, "the year shows only for another year")
        let lastYear = NoteSubtitle.of(note, mode: .audioOnly, now: note.createdAt.addingTimeInterval(400 * 86_400), calendar: calendar)
        guard case .date(_, true)? = lastYear?.day else { Issue.record("no year for an earlier year"); return }
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
        #expect(note.versions?.map(\.kind) == [.beforePassageEdit, .editedPassages])
        #expect(note.versions?[0].segments[0] == original)
        #expect(note.selectedVersionID == stamp.after && note.versions?[1].segments == note.transcript)
        #expect(note.revisePassage(original, to: edited, stamp: stamp) == .changed, "the passage is gone")
        #expect(!note.holds(original) && note.holds(edited))
    }

    /// A run of edits keeps one copy of the transcript, and the chip calls it edited, not transcribed again.
    @Test func editsInARowKeepOneEditedVersion() {
        var note = F.weeklySync
        note.saveCurrentVersion(.transcription)
        let first = note.transcript[0], second = note.transcript[1]
        note.revisePassage(first, to: first.revised(text: "Salve.", speakerID: first.speakerID, speakers: note.speakers!),
                           stamp: VersionStamp(date: Date()))
        #expect(note.versions?.count == 2, "the kept transcription is the version before")
        note.revisePassage(second, to: second.revised(text: "Bene.", speakerID: second.speakerID, speakers: note.speakers!),
                           stamp: VersionStamp(date: Date()))
        #expect(note.versions?.map(\.kind) == [.transcription, .editedPassages])
        #expect(note.versions?[1].segments == note.transcript && note.transcript[1].text == "Bene.")
        #expect(note.versions?[0].segments[0] == first, "the version before keeps the passage as it was")
        #expect(NoteChips.of(note)?.version == VersionChip(index: 2, count: 2, kind: .edited))
        #expect(DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil).versions == 2)
    }

    /// A transcript with its speakers analysed: "Before speaker analysis" and "Speaker analysis", the second shown.
    func analysed() -> Note {
        var note = Note(title: "Conversation")
        note.transcript = [TranscriptSegment(text: "First", start: 0, end: 4), TranscriptSegment(text: "Second", start: 5, end: 9)]
        note.applySpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 4.5), .init(speakerID: "b", start: 5, end: 9)],
                                  matches: [:], voiceNames: [:], autoName: false, stamp: VersionStamp(date: Date()))
        return note
    }

    /// Naming, matching or rejecting a speaker adds no version: the chip and Document info stay at the versions kept,
    /// and the shown one keeps its number and kind (Android counts variants, which naming never changes).
    @Test func namingASpeakerKeepsTheVersionCount() {
        var note = analysed()
        #expect(NoteChips.of(note)?.version == VersionChip(index: 2, count: 2, kind: .transcribedAgain))
        note.renameSpeaker("a", name: "Giulia")
        note.apply([.match(speakerID: "b", .suggested(voice: UUID(), score: 0.7))])
        note.addSpeaker(id: "c", name: "Paolo")
        #expect(note.versions?.map(\.kind) == [.beforeSpeakerAnalysis, .speakerAnalysis])
        #expect(note.versions?[1].speakers == note.speakers && note.versions?[1].segments == note.transcript,
                "the shown version takes the names")
        #expect(note.versions?[0].segments.allSatisfy { $0.speaker == nil } == true, "the version before stays as it was")
        #expect(NoteChips.of(note)?.version == VersionChip(index: 2, count: 2, kind: .transcribedAgain))
        #expect(DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil).versions == 2)
        #expect(note.mergeVersionNumbers == (2, 3))
    }

    /// Naming a speaker between passage edits does not end the run: it still keeps one "Edited passages" version.
    @Test func namingBetweenEditsKeepsOneEditedVersion() {
        var note = analysed()
        let first = note.transcript[0]
        note.revisePassage(first, to: first.revised(text: "Primo.", speakerID: first.speakerID, speakers: note.speakers!),
                           stamp: VersionStamp(date: Date()))
        note.renameSpeaker("a", name: "Giulia")
        #expect(NoteChips.of(note)?.version == VersionChip(index: 3, count: 3, kind: .edited))
        let second = note.transcript[1]
        note.revisePassage(second, to: second.revised(text: "Secondo.", speakerID: second.speakerID, speakers: note.speakers!),
                           stamp: VersionStamp(date: Date()))
        note.rejectVoice(UUID(), for: "b", restorePlaceholder: false)
        let again = note.transcript[1]
        note.revisePassage(again, to: again.revised(text: "Terzo.", speakerID: again.speakerID, speakers: note.speakers!),
                           stamp: VersionStamp(date: Date()))
        #expect(note.versions?.map(\.kind) == [.beforeSpeakerAnalysis, .speakerAnalysis, .editedPassages])
        #expect(note.versions?[2].segments == note.transcript && note.versions?[2].speakers == note.speakers)
        #expect(note.transcript.map(\.speaker) == ["Giulia", "Speaker 2"])
        #expect(NoteChips.of(note)?.version == VersionChip(index: 3, count: 3, kind: .edited))
        #expect(DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil).versions == 3)
    }

    /// Editing an older version keeps it and adds the edits after the kept versions.
    @Test func editingAnOlderVersionAddsTheEditsAfterTheKeptOnes() {
        var note = F.weeklySync
        note.saveCurrentVersion(.transcription)
        let firstID = note.selectedVersionID!
        note.selectedVersionID = nil
        note.transcript[0].text = "Altro."
        note.saveCurrentVersion(.speakerAnalysis)
        note.selectVersion(firstID)
        let passage = note.transcript[0]
        note.revisePassage(passage, to: passage.revised(text: "Salve.", speakerID: passage.speakerID, speakers: note.speakers!),
                           stamp: VersionStamp(date: Date()))
        #expect(note.versions?.map(\.kind) == [.transcription, .speakerAnalysis, .editedPassages])
        #expect(NoteChips.of(note)?.version == VersionChip(index: 3, count: 3, kind: .edited))
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
        note.language = "it-IT"
        note.speakers?[0].match = .confirmed(voice: UUID(), score: 0.9)
        var provenance = TranscriptProvenance(language: "it-IT", inferenceMs: 4_000, resumedFromMs: 0,
                                              speakerDiarization: .sortformer(revision: "r", sha256: "s", elapsedMs: 1,
                                                                              turnCount: 4, speakerCount: 3,
                                                                              streaming: true))
        #expect(DocumentInfoFacts.of(note, provenance: provenance, fileBytes: nil).namesFromVoices == 0,
                "without x-speakerIdentification, as Android reads it")
        provenance.speakerIdentification = .campplus(dim: 512, speakersWithPrints: 3, autoApplied: 1, suggested: 1)
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

    /// Document info shows a language only when it is known (D53.2): Parakeet's `und`, an empty one and an earlier
    /// Mac's `auto` show none. Android shows it only when known too (`NoteViewModel`).
    @Test(arguments: ["", "und", "auto"])
    func documentInfoShowsNoUnknownLanguage(_ stored: String) {
        var note = F.weeklySync
        note.language = stored
        #expect(DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil).language == nil)
    }
}
