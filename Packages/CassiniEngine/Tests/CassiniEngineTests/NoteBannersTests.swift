import Foundation
import Testing
import CassiniCore
import CassiniEngine
import CassiniNotebook

/// The Note screen's job banners, their buttons and their close (Android `NoteViewModel`'s banner part).
@Suite struct NoteBannersTests {
    let plain = Note(title: "Weekly sync", audioFilename: "audio.caf")

    private func job(_ state: JobState, _ kind: JobKind = .transcribe, doneMs: Int64 = 0,
                     failure: JobFailure? = nil) -> Job {
        Job(noteID: plain.id, seq: 1, kind: kind, state: state, failure: failure, doneMs: doneMs, totalMs: 4_000,
            enqueuedAt: Date(timeIntervalSince1970: 1))
    }

    private func document(_ state: DocumentState) -> Note {
        var note = plain
        note.document = DocumentInfo(state: state)
        note.transcript = [TranscriptSegment(text: "Hello.", start: 0, end: 1)]
        return note
    }

    private func text(_ failure: JobFailure) -> String { "failed: \(failure.code)" }

    // ports: NoteViewModelTest#pausedRowsResumeOrStartOverWithConfirmation
    @Test func pausedRowsResumeOrStartOverWithConfirmation() throws {
        let paused = job(.paused, .transcribeAgain, doneMs: 1_000)
        let banner = try #require(NoteBanners.banners(plain, job: paused, failureText: text).first)
        #expect(banner.kind == .txPaused)
        #expect(banner.actions == [.resume, .startOver])
        #expect(NoteBanners.command(for: .resume, note: plain, job: paused) == .transcribe(.transcribeAgain),
                "Resume goes on with the job's kind")
        #expect(NoteBanners.command(for: .startOver, note: plain, job: paused) == .confirmStartOver,
                "Start over asks first")
        #expect(NoteBanners.dismissal(of: banner, note: plain, job: paused) == .hide(id: banner.id))
    }

    // ports: NoteViewModelTest#anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears
    @Test func anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears() throws {
        let note = document(.unverified)
        let failed = job(.failed, .transcribeAgain, failure: .documentRefused(.unverified))
        #expect(NoteBanners.command(for: .transcribeAgain, note: note, job: failed) == nil)

        let banner = try #require(NoteBanners.banners(note, job: failed, failureText: text).first { $0.kind == .txFailed })
        #expect(banner.args.text == "failed: DOCUMENT_UNVERIFIED")
        #expect(banner.actions.isEmpty, "no Try again: it fails the same way")
        #expect(banner.dismissible)
        #expect(NoteBanners.dismissal(of: banner, note: note, job: failed) == .clearJob)
    }

    @Test func aTranscribeAgainOnADocumentThatTakesNoNewVersionIsFinal() throws {
        // The failure itself would let it try again; the document's state does not.
        let failed = job(.failed, .transcribeAgain, failure: .unknown)
        let refused = try #require(NoteBanners.banners(document(.unknownFormat), job: failed, failureText: text).first)
        #expect(refused.actions.isEmpty)
        #expect(NoteBanners.dismissal(of: refused, note: document(.unknownFormat), job: failed) == .clearJob)

        let verified = try #require(NoteBanners.banners(document(.ok), job: failed, failureText: text).first)
        #expect(verified.actions == [.tryAgain])
        #expect(!verified.dismissible)
        #expect(NoteBanners.command(for: .tryAgain, note: document(.ok), job: failed) == .transcribe(.transcribeAgain))
    }

    @Test func oneVoiceOffersTranscribeAgainUnlessTheDocumentRefusesIt() throws {
        var note = document(.ok)
        #expect(NoteBanners.banners(note, job: nil, failureText: text).isEmpty)
        note.speakerAnalysisFailure = .speakers
        #expect(NoteBanners.oneVoice(note))
        let banner = try #require(NoteBanners.banners(note, job: nil, failureText: text).first)
        #expect(banner.kind == .txOneVoice)
        #expect(banner.actions == [.transcribeAgain])
        #expect(NoteBanners.command(for: .transcribeAgain, note: note, job: nil) == .transcribe(.transcribeAgain))

        note.document?.state = .unverified
        #expect(NoteBanners.banners(note, job: nil, failureText: text).first?.actions == [])

        var empty = plain
        empty.speakerAnalysisFailure = .speakers
        #expect(!NoteBanners.oneVoice(empty), "one voice needs a transcript")
    }

    @Test func aNoSpaceDownloadFailureNamesTheInstallsSize() throws {
        let failed = job(.failed, failure: .download(.notEnoughStorage))
        let banner = try #require(NoteBanners.banners(plain, job: failed, failureText: text).first)
        #expect(banner.kind == .dlNoSpace)
        #expect(banner.args.bytes == ModelPlan.installBytes(.speech))
        #expect(banner.args.bytes > 0, "never \"Free about 0 MB\"")
        #expect(NoteBanners.command(for: .retry, note: plain, job: failed) == .transcribe(.transcribe))
        #expect(NoteBanners.command(for: .downloadAgain, note: plain, job: job(.failed, .transcribeAgain))
                == .transcribe(.transcribeAgain))
    }

    @Test func aClosedBannerStaysClosedOnTheScreen() throws {
        let failed = job(.failed, failure: .checkpointMismatch)
        let banner = try #require(NoteBanners.banners(plain, job: failed, failureText: text).first)
        #expect(banner.kind == .txCheckpointMismatch)
        guard case .hide(let id) = NoteBanners.dismissal(of: banner, note: plain, job: failed) else {
            Issue.record("a mismatch is not final"); return
        }
        #expect(NoteBanners.banners(plain, job: failed, failureText: text, dismissed: [id]).isEmpty)
        #expect(NoteBanners.command(for: .open, note: plain, job: failed) == nil, "not a Note banner's action")
    }

    // ports: NoteViewModelTest#aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer (its banners)
    @Test func aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer() throws {
        #expect(NoteBanners.audioOnly(plain, job: nil))
        let banner = try #require(NoteBanners.banners(plain, job: nil, failureText: text).first)
        #expect(NoteBanners.banners(plain, job: nil, failureText: text).map(\.kind) == [.plainAudio])
        #expect(banner.args.text == nil, "No transcript yet.")
        #expect(banner.actions == [.transcribe])
        #expect(NoteBanners.command(for: .transcribe, note: plain, job: nil) == .transcribe(.transcribe))

        var unplayable = document(.ok)
        unplayable.audio = .unplayable(.interrupted)
        #expect(!NoteBanners.audioOnly(unplayable, job: nil))
        #expect(NoteBanners.banners(unplayable, job: nil, failureText: text) == [BannerSpec(.unplayable)])
        unplayable.transcript = []
        unplayable.document = nil
        #expect(NoteBanners.banners(unplayable, job: nil, failureText: text).map(\.kind) == [.unplayable],
                "never Plain audio too")

        // iOS: an imported container this device cannot decode says so.
        unplayable.audio = .unplayable(.unsupportedFormat)
        let opus = NoteBanners.banners(unplayable, job: nil, failureText: text,
                                       unplayableText: { $0 == .unsupportedFormat ? "Can't decode." : nil })
        #expect(opus == [BannerSpec(.unplayable, BannerArgs(text: "Can't decode."))])
    }

    @Test func plainAudioOffersNoTranscribeForAudioTooLongOrStillBeingCaptured() throws {
        var long = plain
        long.duration = Limits.maxTranscribeDuration + 1
        let tooLong = try #require(NoteBanners.banners(long, job: nil, failureText: text).first)
        #expect(tooLong.kind == .plainAudio)
        #expect(tooLong.args.text == "failed: LONG", "says why there is no transcript")
        #expect(tooLong.actions.isEmpty)

        var live = plain
        live.audio = .live
        let capturing = try #require(NoteBanners.banners(live, job: nil, failureText: text).first)
        #expect(capturing.kind == .plainAudio)
        #expect(capturing.args.text == nil)
        #expect(capturing.actions.isEmpty)
    }

    @Test func plainAudioIsOnlyForANoteWithoutTranscriptOrJob() {
        #expect(NoteBanners.audioOnly(plain, job: job(.needsConsent)), "waiting for the speech model is no job yet")
        for state in [JobState.queued, .running, .paused, .failed] {
            #expect(!NoteBanners.audioOnly(plain, job: job(state)))
            #expect(!NoteBanners.banners(plain, job: job(state), failureText: text).contains { $0.kind == .plainAudio })
        }
        #expect(!NoteBanners.audioOnly(document(.ok), job: nil))
        var noSpeech = plain
        noSpeech.status = .ready
        #expect(!NoteBanners.audioOnly(noSpeech, job: nil), "a finished transcript that found no speech")
        var emptyDocument = plain
        emptyDocument.document = DocumentInfo(state: .ok)
        #expect(!NoteBanners.audioOnly(emptyDocument, job: nil))

        let banner = BannerSpec(.plainAudio)
        #expect(NoteBanners.dismissal(of: banner, note: plain, job: nil) == .hide(id: banner.id))
        #expect(NoteBanners.banners(plain, job: nil, failureText: text, dismissed: [banner.id]).isEmpty)
    }
}
