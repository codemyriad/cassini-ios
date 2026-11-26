import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The Note screen's effects through its ports (Android `NoteViewModelTest`, the side the pure `NoteScreenState`
/// tests in CassiniNotebook leave out): the player, the queue and its follow-ups, exports, the start action, the saved
/// draft, the follow timer, and the read-only rule in the screen's sheets.
@MainActor @Suite struct NoteScreenModelTests {
    let fake: FakeNoteScreen
    let model: NoteScreenModel

    init() {
        var note = Note(title: "Weekly sync", audioFilename: "audio.m4a")
        note.status = .ready
        note.duration = 30
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript = [.init(text: "Hello there", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"),
                           .init(text: "Yes", start: 8, end: 12, speaker: "Speaker 2", speakerID: "b")]
        fake = FakeNoteScreen(note: note)
        model = NoteScreenModel(noteID: note.id, ports: fake.ports)
    }

    var noteID: UUID { model.noteID }

    func job(_ state: JobState, _ kind: JobKind = .transcribe) -> Job {
        Job(noteID: noteID, seq: 1, kind: kind, state: state, enqueuedAt: Date(timeIntervalSince1970: 0))
    }

    /// Waits for the screen's background work (a Transcribe, an export) to reach the ports.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    // MARK: The player

    // ports: NoteViewModelTest#leavingTheScreenLeavesThePlayer
    @Test func leavingTheScreenLeavesThePlayer() {
        model.appeared(start: nil)
        #expect(fake.calls == ["showPlayer:audio.m4a"])
        model.disappeared()
        #expect(fake.calls.last == "leavePlayer")
        model.appeared(start: nil)
        #expect(fake.calls.last == "showPlayer:audio.m4a")
    }

    // ports: NoteViewModelTest#aScreenLeftBeforeItsFirstTurnsDoesNotOpenThePlayer
    /// iOS opens the player when the screen appears, not after its first turns; a screen that left before its player
    /// update opens nothing, and leaves nothing it never had.
    @Test func aScreenThatLeftDoesNotOpenThePlayer() {
        model.updatePlayer()
        #expect(fake.calls.isEmpty, "a screen not shown yet opens no player")
        model.appeared(start: nil)
        model.disappeared()
        let calls = fake.calls
        model.updatePlayer()
        #expect(fake.calls == calls, "the left screen does not open the player")
    }

    @Test func aRunningJobOrARecordingLeavesThePlayer() {
        model.appeared(start: nil)
        fake.job = job(.running)
        #expect(model.playerKey == nil)
        model.updatePlayer()
        #expect(fake.calls.last == "leavePlayer")
        fake.job = nil
        fake.playerBlocked = true
        #expect(model.playerKey == nil, "a recording keeps the player closed")
        fake.playerBlocked = false
        #expect(model.playerKey == NotePlayer.key(for: fake.note, blocked: false))
    }

    // ports: NoteViewModelTest#theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges (the effect side)
    @Test func playAnywayAcknowledgesAndPlaysOnlyWhenTheScreenHoldsThePlayer() {
        fake.note?.document = DocumentInfo(state: .unverified)
        fake.ownsPlayer = false
        model.bannerAction(.playAnyway)
        #expect(fake.calls == ["update"])
        #expect(fake.note?.document?.trustAcknowledged == true)
        fake.ownsPlayer = true
        model.bannerAction(.playAnyway)
        #expect(fake.calls.suffix(2) == ["update", "play"])
    }

    @Test func aSeekPlaysFromThereUnlessARecordingHoldsTheAudio() {
        model.seek(12)
        #expect(fake.calls == ["playFrom:12.0"])
        fake.recording = true
        model.seek(20)
        #expect(fake.calls == ["playFrom:12.0"], "no seek while recording")
    }

    // MARK: The queue

    // ports: NoteViewModelTest#theFirstTranscribeAsksForNotificationsOnce (the outcomes; asking once is NoticeCenter's)
    @Test func aTranscribeWithoutConsentOpensTheModelDownloadAndARefusalSaysWhy() async {
        model.bannerAction(.transcribe)
        await eventually { fake.calls.contains("transcribe:transcribe") }
        #expect(!fake.calls.contains("openModelDownload"))

        fake.transcribeOutcome = .needsConsent
        model.sheet = .speakers
        model.bannerAction(.transcribe)
        await eventually { fake.calls.contains("openModelDownload") }
        #expect(model.sheet == nil, "the open sheet gives way to the model download screen")

        fake.transcribeOutcome = .refused(.trashed)
        model.perform(.startOver)
        model.confirmDialog()
        await eventually { !fake.problems.isEmpty }
        guard case .refused(.trashed)? = fake.problems.first else { Issue.record("\(fake.problems)"); return }
    }

    @Test func theCardStopsRemovesAndCancelsTheDownload() {
        model.stopJob()
        model.removeFromQueue()
        model.cancelJobDownload()
        #expect(fake.calls == ["stop", "dequeue", "cancelJobDownload"])
    }

    // ports: NoteViewModelTest#pausedRowsResumeOrStartOverWithConfirmation (the saved draft of a stopped job)
    @Test func theSavedDraftIsReadOnlyForAPausedOrFailedJob() async {
        fake.draft = [DraftWord(speaker: "s1", startMs: 0, endMs: 500, text: "Hello")]
        fake.job = job(.queued)
        await model.loadSavedDraft()
        #expect(model.savedDraft.isEmpty && !fake.calls.contains("savedDraft"), "a queued job shows none")
        fake.job = job(.paused)
        await model.loadSavedDraft()
        #expect(model.savedDraft == fake.draft)
        fake.job = job(.failed)
        await model.loadSavedDraft()
        #expect(model.savedDraft == fake.draft)
        fake.job = nil
        await model.loadSavedDraft()
        #expect(model.savedDraft.isEmpty)
    }

    // MARK: Exports and the start action

    @Test func onlyAnActuallyPresentedVoicesQuestionCountsAsDismissed() {
        model.sheet = .voicesQuestion
        #expect(!model.dismissPresentedSheet(), "A rejected presentation must leave the question unanswered")
        #expect(model.sheet == nil)
        model.sheet = .voicesQuestion
        model.sheetAppeared(.voicesQuestion)
        #expect(model.dismissPresentedSheet(), "Native dismissal after appearance consumes the question")
        #expect(!model.dismissPresentedSheet(), "A duplicate dismissal cannot answer it again")
        model.sheet = .voicesQuestion
        model.sheetAppeared(.voicesQuestion)
        model.sheet = .speakers
        model.sheetAppeared(.voicesQuestion) // A late appearance from a replaced sheet is ignored.
        #expect(!model.dismissPresentedSheet())
        model.sheet = .voicesQuestion
        #expect(!model.dismissPresentedSheet(), "A previous question's appearance cannot leak into a new attempt")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func fileExportStaysBusyUntilSharingOrFailure(audio: Bool, fails: Bool) async {
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let export: @MainActor (UUID) async throws(ExportError) -> URL = { _ throws(ExportError) in
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            if fails { throw .cannotSave }
            return URL(fileURLWithPath: "/unused/export.txt")
        }
        var ports = fake.ports
        ports.copyAudio = export
        ports.exportTranscript = { id, _ throws(ExportError) in try await export(id) }
        let model = NoteScreenModel(noteID: noteID, ports: ports)
        model.perform(audio ? .shareAudio : .exportTranscript(.subtitles))
        #expect(model.exportingFile, "Block the question synchronously, before the export task starts")
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(model.exportingFile && model.shareItem == nil)
        model.perform(.exportDocument)
        #expect(!model.exportingDocument, "Do not overlap file preparation with another export")
        release.continuation.yield(())
        for await busy in ObservedValues({ model.exportingFile }) { if !busy { break } }
        #expect((model.shareItem != nil) == !fails)
        #expect(fake.problems.isEmpty == !fails)
    }

    @Test func anExportIsSharedAndRemovedOnceTheSheetIsDone() async throws {
        model.perform(.exportTranscript(.subtitles))
        await eventually { model.shareItem != nil }
        #expect(fake.calls == ["exportTranscript:subtitles"])
        let item = try #require(model.shareItem)
        item.onComplete?()
        #expect(fake.calls.last == "discard:export.srt")

        fake.exportResult = .failure(.cannotSave)
        model.shareItem = nil
        model.perform(.shareAudio)
        await eventually { !fake.problems.isEmpty }
        #expect(model.shareItem == nil)
        guard case .export(.cannotSave)? = fake.problems.first else { Issue.record("\(fake.problems)"); return }
    }

    @Test func aDocumentThatCannotBeMadeSaysSoAndIsNoLongerBusy() async {
        fake.documentFails = true
        model.perform(.exportDocument)
        #expect(model.exportingDocument)
        await eventually { !model.exportingDocument }
        guard case .documentNotSaved? = fake.problems.first else { Issue.record("\(fake.problems)"); return }
    }

    // ports: NoteViewModelTest#aRowStartedFromTheLibraryRunsOnceOnly
    @Test func theLibrarysStartActionRunsOnceAndOnlyWhileTheScreenIsOpen() async {
        fake.isOpen = false
        model.appeared(start: .export(.subtitles))
        #expect(!fake.calls.contains("markStarted"), "a screen that left the stack runs nothing")
        fake.isOpen = true
        model.runStart(.export(.subtitles))
        await eventually { model.shareItem != nil }
        #expect(fake.calls.filter { $0.hasPrefix("exportTranscript") } == ["exportTranscript:subtitles"])
        model.runStart(.export(.subtitles))
        await Task.yield()
        #expect(fake.calls.filter { $0.hasPrefix("exportTranscript") }.count == 1, "a restored screen does not ask again")
    }

    @Test func reopeningTheVisibleNoteRefreshesQueryAndRunsEachFreshStartOnce() {
        fake.note?.document = DocumentInfo(state: .ok)
        model.appeared(start: nil)
        model.reopened(query: "Thursday", start: .documentInfo)
        #expect(model.screen.search?.query == "Thursday")
        #expect(model.sheet == .documentInfo)
        model.sheet = nil
        model.runStart(.documentInfo)
        #expect(model.sheet == nil, "a layout update must not repeat the consumed action")
        model.screen.search?.setQuery("changed")
        fake.session = NoteSession(opening: fake.session.opening &+ 1)
        model.reopened(query: "Thursday", start: .documentInfo)
        #expect(model.screen.search?.query == "Thursday" && model.sheet == .documentInfo)
        #expect(fake.calls.filter { $0 == "markStarted" }.count == 2)
    }

    @Test func reopeningWithoutAStartStillRefreshesTheSameQueryAndAClosedNoteDoesNothing() {
        model.appeared(start: nil)
        model.reopened(query: "Thursday", start: nil)
        model.screen.closeSearch()
        model.reopened(query: "Thursday", start: nil)
        #expect(model.screen.search?.query == "Thursday")
        #expect(!fake.calls.contains("markStarted"))
        fake.isOpen = false
        model.reopened(query: "ignore", start: .documentInfo)
        #expect(model.screen.search?.query == "Thursday" && model.sheet == nil)
    }

    // ports: NoteViewModelTest#documentInfoCanStartFromTheLibrary
    @Test func documentInfoCanStartFromTheLibrary() {
        fake.note?.origin = .importedDocument
        fake.note?.document = DocumentInfo(state: .ok)
        model.appeared(start: .documentInfo)
        #expect(model.sheet == .documentInfo)
    }

    // ports: NoteViewModelTest#moveToTrashGoesBackToTheLibraryWithUndo (the request; the trash, its undo and the way back
    // to the Library are TrashService's, in TrashServiceTests)
    @Test func moveToTrashAsksRecentlyDeletedOnce() async {
        model.perform(.moveToTrash)
        await eventually { fake.calls.contains("moveToTrash") }
        #expect(fake.calls.filter { $0 == "moveToTrash" }.count == 1)
    }

    /// The Note menu's Transcribe again says what the Library's does: "Adds version 2. Speaker names carry over."
    @Test func transcribeAgainSaysWhichVersionItAddsAndWhetherNamesCarryOver() async {
        fake.note?.speakers?[0].name = "Anna"
        #expect(model.transcribeAction == .transcribeAgain(nextVersion: 2, namesCarry: false))
        fake.speakerModelsReady = true
        model.appeared(start: nil)
        await eventually { model.speakerModelsReady }
        #expect(model.transcribeAction == .transcribeAgain(nextVersion: 2, namesCarry: true))
    }

    // MARK: Follow

    // ports: NoteViewModelTest#aWordTapSeeksAndPlaysAndFollowModeResumes (the timer)
    @Test func aDragPausesFollowingAndTheChipResumesIt() {
        model.scrolled(.dragging, playing: true)
        #expect(!model.screen.follow.following)
        model.resumeFollowing()
        #expect(model.screen.follow.following)
    }

    // MARK: The read-only rule in the sheets

    @Test func aPendingJobLocksTheSpeakersListAndTheEditor() async {
        fake.job = job(.queued, .speakersOnly)
        #expect(model.readOnly == .jobPending && !model.speakersEditable)
        #expect(!model.addSpeaker(named: "Bruno"))
        await model.identifySpeakers()
        model.speakerTapped("a")
        #expect(model.screen.dialog == .readOnly(.jobPending), "the screen says why")
        #expect(model.sheet == nil)
        let passage = fake.note!.transcript[0]
        var revised = passage
        revised.text = "Hi there"
        #expect(await model.revisePassage(passage, to: revised, stamp: VersionStamp(date: .now)) == .locked)
        await model.answer(SpeakerSuggestion(speakerID: "a", label: "Speaker 1", voiceID: UUID(), voiceName: "Luca", score: 0.7, segmentID: UUID(), start: 0),
                           yes: true)
        #expect(!fake.calls.contains { $0.hasPrefix("addSpeaker") || $0.hasPrefix("transcribe") || $0 == "commit" || $0.hasPrefix("answer") })

        fake.job = nil
        #expect(model.addSpeaker(named: "Bruno"))
        #expect(fake.calls.last == "addSpeaker:Bruno")
        #expect(await model.revisePassage(passage, to: revised, stamp: VersionStamp(date: .now)) == .saved)
        #expect(await model.revisePassage(passage, to: revised, stamp: VersionStamp(date: .now)) == .changed,
                "the passage is no longer as it was")
    }

    @Test func identifySpeakersWithoutConsentClosesTheListForTheModelDownload() async {
        fake.transcribeOutcome = .needsConsent
        model.sheet = .speakers
        await model.identifySpeakers()
        #expect(fake.calls == ["transcribe:speakersOnly", "openModelDownload"])
        #expect(model.sheet == nil)
    }

    @Test func choosingAVersionShowsItAndClosesTheSheet() {
        let version = UUID()
        model.sheet = .versions
        model.selectVersion(version)
        #expect(fake.calls == ["selectVersion:\(version)"])
        #expect(model.sheet == nil)
    }

    @Test func aSuggestionAnswerThatCannotBeSavedSaysWhy() async {
        fake.namingFailure = VoicesStore.SaveFailure(reason: .noteNotSaved)
        await model.answer(SpeakerSuggestion(speakerID: "a", label: "Speaker 1", voiceID: UUID(), voiceName: "Luca", score: 0.7, segmentID: UUID(), start: 0),
                           yes: false)
        #expect(fake.calls == ["answer:false"])
        guard case .speakerNotSaved? = fake.problems.first else { Issue.record("\(fake.problems)"); return }
    }

    @Test func marksAndBookmarks() {
        let bookmark = UUID()
        model.markMoment(at: 4)
        #expect(model.showBookmarks)
        model.removeBookmark(bookmark)
        #expect(fake.calls == ["markMoment:4.0", "removeBookmark:\(bookmark)"])
    }

    @Test func openingNameSpeakerOnLongTranscriptUsesCachedHeaderSpeakersOrPreparesOffMain() async throws {
        // Catalog order is [s1, s2, s3], while canonical word order is [s2, s3, s1] over a long transcript.
        var longNote = Note(title: "Long meeting", audioFilename: "audio.m4a")
        longNote.status = .ready
        longNote.duration = 2_400
        longNote.speakers = [
            NoteSpeaker(id: "s1", name: "Alpha", colourIndex: 0, provenance: .user),
            NoteSpeaker(id: "s2", name: "Beta", colourIndex: 1, provenance: .user),
            NoteSpeaker(id: "s3", name: "Gamma", colourIndex: 2, provenance: .user),
        ]
        let order = ["s2", "s3", "s1"]
        longNote.transcript = (0..<1_200).map { i in
            let spk = order[i % order.count]
            let start = Double(i * 2)
            return TranscriptSegment(
                text: "word\(i) more\(i)", start: start, end: start + 1.5,
                speaker: spk, speakerID: spk,
                words: [
                    TimedWord(text: "word\(i)", start: start, end: start + 0.7),
                    TimedWord(text: "more\(i)", start: start + 0.8, end: start + 1.5),
                ]
            )
        }
        let longFake = FakeNoteScreen(note: longNote)
        let longModel = NoteScreenModel(noteID: longNote.id, ports: longFake.ports)

        // 1. With a prepared TranscriptCache, naming(...) derives the canonical roster immediately without rebuilding.
        let cache = TranscriptCache()
        await cache.prepareSealed(TranscriptCache.SealedKey(longNote, voices: [], suggestions: []))
        let cachedHeaders = try #require(cache.allHeaderSpeakers(for: longNote))
        let cachedSheet = longModel.naming("s1", allHeaderSpeakers: cachedHeaders)
        #expect(cachedSheet.displayedRoster.map(\.speakerID) == ["s2", "s3", "s1"])

        // 2. Without a cached snapshot, naming(...) does not rebuild synchronously on MainActor (starts with catalog
        //    fallback) and upgrades to canonical word order off-main when open(...) runs.
        let uncachedSheet = longModel.naming("s1")
        #expect(uncachedSheet.displayedRoster.map(\.speakerID) == ["s1", "s2", "s3"])
        await uncachedSheet.open(draft: nil) { _ in }
        #expect(uncachedSheet.displayedRoster.map(\.speakerID) == ["s2", "s3", "s1"])
    }
}
