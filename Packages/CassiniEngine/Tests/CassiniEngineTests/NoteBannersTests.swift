import Foundation
import Testing
import CassiniCore
import CassiniEngine
import CassiniNotebook

/// The Note screen's banners for its mode, their buttons and their close (Android `NoteViewModel`'s banner part, with
/// `NoteScreenState` carrying out the buttons).
@Suite struct NoteBannersTests {
    let plain = Note(title: "Weekly sync", audioFilename: "audio.caf")

    private var transcribed: Note {
        var note = plain
        note.transcript = [TranscriptSegment(text: "Hello.", start: 0, end: 1)]
        note.status = .ready
        return note
    }

    private func job(_ state: JobState, _ kind: JobKind = .transcribe, doneMs: Int64 = 0, failure: JobFailure? = nil,
                     pause: PauseReason? = nil) -> Job {
        Job(noteID: plain.id, seq: 1, kind: kind, state: state, pauseReason: pause, failure: failure, doneMs: doneMs,
            totalMs: 4_000, enqueuedAt: Date(timeIntervalSince1970: 1))
    }

    private func document(_ state: DocumentState, acknowledged: Bool = false) -> Note {
        var note = transcribed
        note.origin = .importedDocument
        note.document = DocumentInfo(state: state, trustAcknowledged: acknowledged)
        return note
    }

    private func text(_ failure: JobFailure) -> String { "failed: \(failure.code)" }

    /// The banners of `note` in the mode its `job` gives.
    private func banners(_ note: Note, job: Job? = nil, facts: NoteBannerFacts = NoteBannerFacts(),
                         unplayableText: (UnplayableReason) -> String? = { _ in nil }) -> [BannerSpec] {
        NoteBanners.banners(note, job: job, mode: NoteMode.of(note, job: job), facts: facts, failureText: text,
                            unplayableText: unplayableText)
    }

    @Test func unavailableSpeechExplainsAndDisablesTheVisibleTranscribeAction() throws {
        let available = try #require(banners(plain).first)
        #expect(available.actions.contains(.transcribe))
        #expect(available.disabledActions.isEmpty)
        let unavailable = try #require(banners(plain, facts: NoteBannerFacts(speechUnavailableText: "No speech model.")).first)
        #expect(unavailable.args.text == "No speech model.")
        #expect(unavailable.actions.contains(.transcribe))
        #expect(unavailable.disabledActions == [.transcribe])
    }

    // ports: NoteViewModelTest#pausedRowsResumeOrStartOverWithConfirmation (its banner)
    @Test func pausedRowsResumeOrStartOverWithConfirmation() throws {
        let paused = job(.paused, .transcribeAgain, doneMs: 1_000)
        let banner = try #require(banners(transcribed, job: paused).first)
        #expect(banner.kind == .txPaused)
        #expect(banner.args.ms1 == 1_000 && banner.args.ms2 == 4_000)
        #expect(banner.actions == [.resume, .startOver])
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.resume, note: transcribed, job: paused) == .transcribe(.transcribeAgain),
                "Resume goes on with the job's kind")
        #expect(screen.bannerAction(.startOver, note: transcribed, job: paused) == nil)
        #expect(screen.dialog == .startOver, "Start over asks first")
        #expect(screen.dismiss(banner, note: transcribed, job: paused) == nil)
        #expect(screen.dismissed == [banner.id])
    }

    // ports: NoteViewModelTest#anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears
    @Test func anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears() throws {
        let note = document(.unverified)
        let failed = job(.failed, .transcribeAgain, failure: .documentRefused(.unverified))
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.transcribeAgain, note: note, job: failed) == nil)
        #expect(screen.dialog == nil, "nothing to confirm either")

        let banner = try #require(banners(note, job: failed).first { $0.kind == .txFailed })
        #expect(banner.args.text == "failed: DOCUMENT_UNVERIFIED")
        #expect(banner.actions.isEmpty, "no Try again: it fails the same way")
        #expect(banner.dismissible)
        #expect(screen.dismiss(banner, note: note, job: failed) == .clearFailed)
        #expect(screen.dismissed.isEmpty)
    }

    @Test func aTranscribeAgainOnADocumentThatTakesNoNewVersionIsFinal() throws {
        // The failure itself would let it try again; the document's state does not.
        let failed = job(.failed, .transcribeAgain, failure: .unknown)
        let refused = try #require(banners(document(.unknownFormat), job: failed).first { $0.kind == .txFailed })
        #expect(refused.actions.isEmpty)
        var screen = NoteScreenState()
        #expect(screen.dismiss(refused, note: document(.unknownFormat), job: failed) == .clearFailed)

        let verified = try #require(banners(document(.ok), job: failed).first)
        #expect(verified.kind == .txFailed)
        #expect(verified.actions == [.tryAgain])
        #expect(!verified.dismissible)
        #expect(screen.bannerAction(.tryAgain, note: document(.ok), job: failed) == .transcribe(.transcribeAgain))
    }

    // ports: NoteViewModelTest#theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges
    @Test func theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges() {
        let verified = document(.ok)
        var screen = NoteScreenState()
        func kinds(_ note: Note) -> [BannerKind] {
            banners(note, facts: NoteBannerFacts(trustToggled: screen.trustToggled)).map(\.kind)
        }
        #expect(kinds(verified).isEmpty)
        screen.toggleTrust()
        #expect(kinds(verified) == [.trustVerified])
        screen.toggleTrust()
        #expect(kinds(verified).isEmpty)

        let unverified = document(.unverified)
        #expect(kinds(unverified) == [.trustNotVerified])
        #expect(banners(unverified).first?.actions == [.playAnyway])
        #expect(screen.bannerAction(.playAnyway, note: unverified, job: nil) == .acknowledgeTrustAndPlay)
        #expect(kinds(document(.unverified, acknowledged: true)).isEmpty, "acknowledged: the banner stays hidden")
    }

    /// A changed document's trust banner offers Transcribe again, which asks first: earlier versions can't be kept.
    @Test func aChangedDocumentsTrustBannerTranscribesFresh() throws {
        let note = document(.staleAudio)
        let banner = try #require(banners(note).first)
        #expect(banner.kind == .trustAudioChanged)
        #expect(banner.actions == [.transcribeAgain])
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.transcribeAgain, note: note, job: nil) == nil)
        #expect(screen.dialog == .transcribeFresh)
        #expect(banners(document(.unknownFormat)).first?.actions == [], "a newer format offers nothing")
    }

    @Test func oneVoiceOffersTranscribeAgainUnlessTheDocumentRefusesIt() throws {
        var note = document(.ok)
        #expect(banners(note).isEmpty)
        note.speakerAnalysisFailure = .speakers
        #expect(NoteBanners.oneVoice(note))
        let banner = try #require(banners(note).first)
        #expect(banner.kind == .txOneVoice)
        #expect(banner.actions == [.transcribeAgain])
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.transcribeAgain, note: note, job: nil) == .transcribe(.transcribeAgain))
        #expect(banners(note, job: job(.queued)).isEmpty, "only without a job")

        note.document?.state = .unverified
        #expect(banners(note).first { $0.kind == .txOneVoice }?.actions == [])

        var empty = plain
        empty.speakerAnalysisFailure = .speakers
        #expect(!NoteBanners.oneVoice(empty), "one voice needs a transcript")
    }

    @Test func missingSpeakerModelsOfferTheirDownloadWithoutRepeatingSpeech() throws {
        var note = transcribed
        note.speakerAnalysisFailure = .speakers
        let facts = NoteBannerFacts(speakerModelsMissing: true)
        let banner = try #require(banners(note, facts: facts).first)
        #expect(banner.kind == .txOneVoice)
        #expect(banner.actions == [.download])
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.download, note: note, job: nil) == .transcribe(.speakersOnly))
        #expect(banners(note, job: job(.queued), facts: facts).isEmpty)
        #expect(screen.bannerAction(.download, note: note, job: job(.queued)) == nil)
        #expect(screen.bannerAction(.download, note: plain, job: nil) == nil)
        #expect(banners(note).first?.actions == [.transcribeAgain], "Installed models keep the existing retry")
        let installing = try #require(banners(note, facts: NoteBannerFacts(speakerModelsInstalling: true)).first)
        #expect(installing.actions == [.download])
        #expect(installing.disabledActions == [.download], "Installing models must not switch back to repeating speech")
        note.document = DocumentInfo(state: .unverified)
        #expect(banners(note, facts: facts).first { $0.kind == .txOneVoice }?.actions == [])
        #expect(screen.bannerAction(.download, note: note, job: nil) == nil)
    }

    @Test func speakerDownloadWaitsForAvailabilityAndTracksEachInstallState() throws {
        var note = transcribed
        note.speakerAnalysisFailure = .speakers
        let cases: [(ModelPartStatus?, Bool, Bool)] = [
            (nil, false, true), (.checking, false, true), (.downloading(0.5), false, true),
            (.notDownloaded, true, false), (.failed(.fileCheckFailed), true, false),
            (.ready, false, false), (.unsupported, false, false)]
        for (status, missing, installing) in cases {
            let state = NoteBanners.speakerDownloadState(status)
            #expect(state.missing == missing)
            #expect(state.installing == installing)
            let banner = try #require(banners(note, facts: NoteBannerFacts(
                speakerModelsMissing: state.missing, speakerModelsInstalling: state.installing)).first)
            #expect(banner.actions == (missing || installing ? [.download] : [.transcribeAgain]))
            #expect(banner.disabledActions == (installing ? [.download] : []))
        }
    }

    /// iOS: a speaker step that found nobody is no one-voice banner, but its own notice.
    @Test func noSpeakersIsNotOneVoice() {
        var note = transcribed
        note.speakerAnalysisFailure = .empty
        #expect(!NoteBanners.oneVoice(note))
        #expect(banners(note).isEmpty)
        #expect(NoteBanners.noSpeakers(note, job: nil))
        #expect(!NoteBanners.noSpeakers(note, job: job(.queued)))
    }

    @Test func aNoSpaceDownloadFailureNamesTheInstallsSize() throws {
        let failed = job(.failed, failure: .download(.notEnoughStorage))
        let banner = try #require(banners(plain, job: failed).first)
        #expect(banner.kind == .dlNoSpace)
        #expect(banner.args.bytes == ModelDownloadPlan.speechInstallBytes)
        #expect(banner.args.bytes > 0, "never \"Free about 0 MB\"")
        // On a Parakeet device the facts carry what Ultra's install asks for.
        let facts = NoteBannerFacts(speechInstallBytes: 1_290_000_000, speakersInstallBytes: 125_000_000)
        let parakeet = try #require(banners(plain, job: failed, facts: facts).first)
        #expect(parakeet.args.bytes == 1_290_000_000)
        // Identify speakers installs only the speaker models: it asks for their figure, not Ultra's.
        let speakers = job(.failed, .speakersOnly, failure: .download(.notEnoughStorage))
        let identify = try #require(banners(transcribed, job: speakers, facts: facts).first { $0.kind == .dlNoSpace })
        #expect(identify.args.bytes == 125_000_000)
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.retry, note: plain, job: failed) == .transcribe(.transcribe))
        #expect(screen.bannerAction(.downloadAgain, note: plain, job: job(.failed, .transcribeAgain))
                == .transcribe(.transcribeAgain))
    }

    /// A closed banner stays closed on the screen; a failure with saved progress offers Try again and Start over.
    @Test func aClosedBannerStaysClosedOnTheScreen() throws {
        var screen = NoteScreenState()
        let failed = job(.failed, doneMs: 1_000, failure: .save)
        let banner = try #require(banners(transcribed, job: failed).first)
        #expect(banner.kind == .txFailed && banner.actions == [.tryAgain, .startOver])
        #expect(screen.dismiss(banner, note: transcribed, job: failed) == nil)
        #expect(banners(transcribed, job: failed, facts: NoteBannerFacts(dismissed: screen.dismissed)).isEmpty)

        let mismatch = job(.failed, failure: .checkpointMismatch)
        #expect(banners(transcribed, job: mismatch).map(\.kind) == [.txCheckpointMismatch])
        #expect(screen.bannerAction(.open, note: transcribed, job: mismatch) == nil, "not a Note banner's action")
    }

    /// The held queue shows below a paused job only; a pause for memory shows as a pause (iOS has no TX_MEMORY).
    @Test func theHeldQueueFollowsAPausedJob() {
        let paused = job(.paused, pause: .system)
        let held = banners(plain, job: paused, facts: NoteBannerFacts(queueHold: .user, waitingJobs: 2))
        #expect(held.map(\.kind) == [.txPausedEarly, .txQueueHeld])
        #expect(held[0].args.bySystem && held[1].args.count == 2)
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.continue, note: plain, job: paused) == .continueQueue)
        #expect(!banners(plain, job: job(.failed), facts: NoteBannerFacts(queueHold: .user, waitingJobs: 2))
            .contains { $0.kind == .txQueueHeld })
        #expect(banners(plain, job: job(.paused, doneMs: 10, pause: .memory)).map(\.kind) == [.txPaused])
    }

    // ports: NoteViewModelTest#aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer (its banners)
    @Test func aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer() throws {
        #expect(NoteMode.of(plain, job: nil) == .audioOnly)
        let banner = try #require(banners(plain).first)
        #expect(banners(plain).map(\.kind) == [.plainAudio])
        #expect(banner.args.text == nil, "No transcript yet.")
        #expect(banner.actions == [.transcribe])
        #expect(!banner.dismissible)
        var screen = NoteScreenState()
        #expect(screen.bannerAction(.transcribe, note: plain, job: nil) == .transcribe(.transcribe))

        var unplayable = document(.ok)
        unplayable.audio = .unplayable(.interrupted)
        #expect(banners(unplayable) == [BannerSpec(.unplayable)], "no trust banner without the reading content")
        unplayable.transcript = []
        unplayable.document = nil
        #expect(banners(unplayable).map(\.kind) == [.unplayable], "never Plain audio too")

        // iOS: an imported container this device cannot decode says so.
        unplayable.audio = .unplayable(.unsupportedFormat)
        let opus = banners(unplayable, unplayableText: { $0 == .unsupportedFormat ? "Can't decode." : nil })
        #expect(opus == [BannerSpec(.unplayable, BannerArgs(text: "Can't decode."))])
    }

    @Test func plainAudioOffersNoTranscribeForAudioTooLongOrStillBeingCaptured() throws {
        var long = plain
        long.duration = Limits.maxTranscribeDuration + 1
        let tooLong = try #require(banners(long).first)
        #expect(tooLong.kind == .plainAudio)
        #expect(tooLong.args.text == "failed: LONG", "says why there is no transcript")
        #expect(tooLong.actions.isEmpty)

        var live = plain
        live.audio = .live
        let capturing = try #require(banners(live).first)
        #expect(capturing.kind == .plainAudio)
        #expect(capturing.args.text == nil)
        #expect(capturing.actions.isEmpty)
    }

    @Test func plainAudioIsOnlyForANoteWithoutTranscriptOrJob() {
        #expect(banners(plain, job: job(.needsConsent)).map(\.kind) == [.plainAudio],
                "waiting for the speech model is no job yet")
        for state in [JobState.queued, .running, .paused, .failed] {
            #expect(!banners(plain, job: job(state)).contains { $0.kind == .plainAudio })
        }
        #expect(!banners(document(.ok)).contains { $0.kind == .plainAudio })
        var noSpeech = plain
        noSpeech.status = .ready
        #expect(banners(noSpeech).isEmpty, "a finished transcript that found no speech")
        var emptyDocument = plain
        emptyDocument.document = DocumentInfo(state: .ok)
        #expect(banners(emptyDocument).isEmpty)

        let banner = BannerSpec(.plainAudio)
        #expect(banners(plain, facts: NoteBannerFacts(dismissed: [banner.id])).isEmpty)
    }
}
