import Foundation
import Testing
import CassiniNotebook

/// Every app-emitted banner row comes out of `Notices` from constructed facts, with the catalogue's arguments and
/// actions; the lists are ordered failed, attention, info, plain, newest first within a tone.
@Suite struct NoticesTests {
    let note = UUID()
    let active = ActiveRecording(noteID: UUID(), title: "Standup", defaultTitle: "Voice note", format: .pcm48kMono,
                                 elapsed: 60)

    private func job(_ state: JobState, doneMs: Int64 = 0, reason: PauseReason? = nil, failure: JobFailure? = nil,
                     kind: JobKind = .transcribe) -> Job {
        Job(noteID: note, seq: 1, kind: kind, state: state, pauseReason: reason, failure: failure, doneMs: doneMs,
            totalMs: 2_052_000, enqueuedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    }

    private func only(_ list: [BannerSpec], sourceLocation: SourceLocation = #_sourceLocation) -> BannerSpec? {
        #expect(list.count == 1, "\(list)", sourceLocation: sourceLocation)
        return list.first
    }

    private func recording(_ recording: ActiveRecording) -> RecordingState { .active(recording) }

    // ports: NoticeCenterTest#recordingRows
    @Test func recordingRows() {
        var paused = active
        paused.pause = .otherApp
        #expect(only(Notices.recording(.active(paused), microphoneOff: false)) == BannerSpec(.recPausedOtherApp, announce: true))
        paused.pause = .user
        #expect(Notices.recording(.active(paused), microphoneOff: false).isEmpty)
        paused.pause = .routeLost
        #expect(only(Notices.recording(.active(paused), microphoneOff: false))?.kind == .recInputLost)

        var low = active
        low.warning = .lowStorage(minutesLeft: 10)
        #expect(only(Notices.recording(.active(low), microphoneOff: false))
                == BannerSpec(.recStorageLow, BannerArgs(ms1: 600_000), announce: true))

        let stopped = only(Notices.recording(.ended(noteID: note, outcome: .stoppedForSpace), microphoneOff: false))
        #expect(stopped?.kind == .recStoppedStorage)
        #expect(stopped?.args.bytes == Limits.minRecordingFreeBytes)
        #expect(stopped?.actions == [.openNote])

        let micOff = only(Notices.recording(.idle, microphoneOff: true))
        #expect(micOff?.kind == .recMicOff)
        #expect(micOff?.actions == [.openSettings])
        #expect(only(Notices.recording(.idle, microphoneOff: false, ended: .microphoneFailed))?.kind == .recMicFailed)
        let start = only(Notices.recording(.ended(noteID: nil, outcome: .couldNotStart), microphoneOff: false))
        #expect(start?.kind == .recCouldNotStart)
        #expect(start?.actions == [.tryAgain])
        #expect(Notices.recording(.ended(noteID: note, outcome: .saved(.transcribe)), microphoneOff: false).isEmpty)
    }

    // ports: NoticeCenterTest#recoveredRow
    @Test func recoveredRow() {
        let first = RecoveredRecording(noteID: UUID(), recoveredAt: Date(timeIntervalSince1970: 40), duration: 20)
        let latest = RecoveredRecording(noteID: UUID(), recoveredAt: Date(timeIntervalSince1970: 50), duration: 312)
        let spec = only(Notices.library(NoticeFacts(recovered: [first, latest]), LibraryFacts(loading: true)))
        #expect(spec?.kind == .recovered)
        #expect(spec?.args == BannerArgs(count: 2, ms1: 312_000), "the count, and the time of the latest")
        #expect(spec?.actions == [.open])
        #expect(spec?.dismissible == true)
    }

    // ports: NoticeCenterTest#transcriptionRows
    @Test func transcriptionRows() {
        let paused = only(Notices.job(job(.paused, doneMs: 760_000, reason: .user)))
        #expect(paused?.kind == .txPaused)
        #expect(paused?.args == BannerArgs(ms1: 760_000, ms2: 2_052_000))
        #expect(paused?.actions == [.resume, .startOver])
        // iOS took the background time back: the banner says so.
        let bySystem = only(Notices.job(job(.paused, doneMs: 1, reason: .system)))
        #expect(bySystem?.kind == .txPaused)
        #expect(bySystem?.args == BannerArgs(ms1: 1, ms2: 2_052_000, bySystem: true))
        let early = only(Notices.job(job(.paused, reason: .interrupted)))
        #expect(early?.kind == .txPausedEarly)
        #expect(early?.args.bySystem == false)
        #expect(only(Notices.job(job(.paused, reason: .system)))?.args.bySystem == true)
        // No TX_MEMORY on iOS: a pause for memory is a pause.
        #expect(only(Notices.job(job(.paused, doneMs: 5, reason: .memory)))?.kind == .txPaused)
        #expect(only(Notices.job(job(.failed, failure: .checkpointMismatch)))?.kind == .txCheckpointMismatch)

        let failed = only(Notices.job(job(.failed, failure: .audio), failureText: "No audio."))
        #expect(failed?.kind == .txFailed)
        #expect(failed?.args.text == "No audio.")
        #expect(failed?.actions == [.tryAgain])
        #expect(only(Notices.job(job(.failed, doneMs: 9, failure: .audio)))?.actions == [.tryAgain, .startOver])
        #expect(only(Notices.job(nil, oneVoice: true))?.kind == .txOneVoice)

        // A refused document fails the same way on every try: no Try again, and the banner can be dismissed.
        let refused = job(.failed, doneMs: 9, failure: .documentRefused(.unverified))
        let final = only(Notices.job(refused, failureText: "Not checked."))
        #expect(final?.kind == .txFailed)
        #expect(final?.actions == [])
        #expect(final?.dismissible == true)
        #expect(Notices.finalFailure(refused, noNewVersion: false))
        #expect(Notices.finalFailure(job(.failed, failure: .long), noNewVersion: false))
        let again = job(.failed, failure: .audio, kind: .transcribeAgain)
        #expect(Notices.finalFailure(again, noNewVersion: true))
        #expect(!Notices.finalFailure(again, noNewVersion: false))
        #expect(only(Notices.job(again, noNewVersion: true))?.actions == [])
        #expect(only(Notices.job(nil, oneVoice: true, noNewVersion: true))?.actions == [])
        #expect(Notices.job(job(.queued)).isEmpty)
        #expect(Notices.job(job(.running)).isEmpty)
        #expect(Notices.job(job(.needsConsent)).isEmpty)
        #expect(Notices.job(job(.running), oneVoice: true).isEmpty, "one voice shows only once the job is gone")

        let held = only(Notices.library(NoticeFacts(queueHold: .user, waitingJobs: 3), LibraryFacts(loading: true)))
        #expect(held == BannerSpec(.txQueueHeld, BannerArgs(count: 3)))
        #expect(Notices.library(NoticeFacts(queueHold: .user, waitingJobs: 0), LibraryFacts(loading: true)).isEmpty)
    }

    // ports: NoticeCenterTest#downloadRows
    @Test func downloadRows() {
        let at = Date(timeIntervalSince1970: 9)
        let downloading = Notices.modelDownload(DownloadFact(part: .speakers, fraction: 0.46, at: at))
        #expect(downloading?.kind == .dlDownloading)
        #expect(downloading?.args == BannerArgs(percent: 46, part: .speakers))
        #expect(downloading?.actions == [.cancel])
        #expect(Notices.modelDownload(DownloadFact(part: .speech, at: at))?.args.percent == 0, "before its size is known")
        #expect(Notices.modelDownload(nil) == nil)

        let kinds: [DownloadError: BannerKind] = [
            .noConnection: .dlNoConnection, .interrupted: .dlStopped, .hostNotAllowed: .dlStopped,
            .stoppedBySystem: .dlStopped, .notEnoughStorage: .dlNoSpace, .fileCheckFailed: .dlFileCheck,
            .install: .dlInstallFailed,
        ]
        #expect(Set(kinds.keys) == Set(DownloadError.allCases))
        for (error, kind) in kinds {
            let fact = DownloadFact(part: .speech, failure: error, requiredFreeBytes: 901_000_000, at: at)
            #expect(Notices.modelDownload(fact)?.kind == kind)
            #expect(only(Notices.job(job(.failed, failure: .download(error)), requiredFreeBytes: 5))?.kind == kind)
        }
        #expect(Notices.download(.notEnoughStorage, requiredFreeBytes: 901_000_000).args.bytes == 901_000_000)
        // iOS stopped it: the body says so, not that the connection dropped.
        #expect(Notices.download(.stoppedBySystem).args.bySystem)
        #expect(!Notices.download(.interrupted).args.bySystem)
        #expect(Notices.download(.fileCheckFailed).actions == [.downloadAgain])

        let failure = DownloadFact(part: .speech, failure: .noConnection, at: at)
        #expect(only(Notices.library(NoticeFacts(download: failure), LibraryFacts(loading: true)))?.kind == .dlNoConnection)
        let running = DownloadFact(part: .speech, fraction: 0.5, at: at)
        #expect(Notices.library(NoticeFacts(download: running), LibraryFacts(loading: true)).isEmpty,
                "the Library shows a download's failure, not its progress")

        let audioOnly = LibraryFacts(liveNotes: 1, audioOnly: true)
        #expect(only(Notices.library(NoticeFacts(consented: false), audioOnly)) == BannerSpec(.dlRecordNow))
        #expect(Notices.library(NoticeFacts(consented: true), audioOnly).isEmpty)
        #expect(Notices.library(NoticeFacts(consented: false), LibraryFacts(liveNotes: 1)).isEmpty)
    }

    // ports: NoticeCenterTest#libraryAndImportRows
    @Test func libraryAndImportRows() {
        #expect(only(Notices.library(NoticeFacts(), LibraryFacts(liveNotes: 0))) == BannerSpec(.libEmpty))
        #expect(BannerKind.libEmpty.actions == [.record, .import])
        let loading = LibraryFacts(loading: true)
        #expect(Notices.library(NoticeFacts(), loading).isEmpty, "no empty banner while loading")
        #expect(only(Notices.library(NoticeFacts(), LibraryFacts(liveNotes: 0, query: " fattura ", results: 0)))
                == BannerSpec(.libNoMatch, BannerArgs(text: "fattura")))
        #expect(Notices.library(NoticeFacts(), LibraryFacts(liveNotes: 3, query: "x", results: nil)).isEmpty)
        #expect(only(Notices.library(NoticeFacts(), LibraryFacts(unavailable: true)))?.kind == .libUnavailable)
        #expect(only(Notices.library(NoticeFacts(libraryUnavailable: true), LibraryFacts()))?.kind == .libUnavailable)

        let importing = only(Notices.library(NoticeFacts(importing: ["a.mp3", "call.m4a"]), loading))
        #expect(importing == BannerSpec(.importing, BannerArgs(text: "call.m4a"), announce: true))

        let failures: [(ImportFailureKind, BannerKind)] = [
            (.tooLarge, .importTooLarge), (.noSpace(bytesNeeded: 1_400_000_000), .importNoSpace),
            (.cannotOpen, .importOpen), (.cannotSave, .importOpen),
        ]
        for (failure, kind) in failures {
            let facts = NoticeFacts(importFailure: ImportFailureFact(displayName: "x", kind: failure, at: .distantPast))
            let spec = only(Notices.library(facts, loading))
            #expect(spec?.kind == kind)
            #expect(spec?.dismissible == true, "import errors close until the next import")
        }
        let noSpace = ImportFailureFact(displayName: "x", kind: .noSpace(bytesNeeded: 1_400_000_000), at: .distantPast)
        #expect(only(Notices.library(NoticeFacts(importFailure: noSpace), loading))?.args.bytes == 1_400_000_000)

        #expect(only(Notices.library(NoticeFacts(jobRunning: true, notificationsOff: true), loading))?.kind == .notificationsOff)
        #expect(Notices.library(NoticeFacts(notificationsOff: true), loading).isEmpty, "the Library tells only while a job runs")
        #expect(only(Notices.settings(NoticeFacts(notificationsOff: true)))?.kind == .notificationsOff)
        #expect(only(Notices.settings(NoticeFacts(voicesUnavailable: true)))?.kind == .voicesUnreadable)

        let unreadable = only(Notices.library(NoticeFacts(unreadableNotes: 2), loading))
        #expect(unreadable == BannerSpec(.notesUnreadable, BannerArgs(count: 2)))
        #expect(unreadable?.dismissible == true)
        let compression = only(Notices.library(NoticeFacts(compressionFailedAt: .distantPast), loading))
        #expect(compression?.kind == .recCompressionFailed)
        #expect(compression?.dismissible == true)
    }

    // ports: NoticeCenterTest#everyAppEmittedRowIsProduced
    @Test func everyAppEmittedRowIsProduced() {
        let produced = Set(produceAll().map(\.kind))
        let expected = Set(BannerKind.allCases.filter { $0.appEmitted && $0.group != .trust })
        #expect(expected.subtracting(produced).isEmpty, "\(expected.subtracting(produced))")
        #expect(!produced.contains(.txCalculating) && !produced.contains(.txBattery))
    }

    // ports: NoticeCenterTest#ordersFailedAttentionInfoPlainNewestFirst
    @Test func ordersFailedAttentionInfoPlainNewestFirst() {
        let facts = NoticeFacts(
            recovered: [RecoveredRecording(noteID: note, recoveredAt: Date(timeIntervalSince1970: 10), duration: 1)],
            compressionFailedAt: Date(timeIntervalSince1970: 3),
            queueHold: .user, waitingJobs: 1, consented: false,
            importing: ["a.mp3"],
            importFailure: ImportFailureFact(displayName: "b.wav", kind: .cannotOpen, at: Date(timeIntervalSince1970: 5)),
            download: DownloadFact(part: .speech, failure: .noConnection, at: Date(timeIntervalSince1970: 9)))
        let kinds = Notices.library(facts, LibraryFacts(liveNotes: 0, audioOnly: true)).map(\.kind)
        #expect(kinds == [
            .dlNoConnection, // error, at 9
            .importOpen, // error, at 5
            .txQueueHeld, // warn
            .recovered, // info, at 10
            .recCompressionFailed, // info, at 3
            .dlRecordNow, // info, catalogue order
            .importing,
            .libEmpty, // plain
        ])
    }

    @Test func twoFactsAtOnceBothShowInToneOrder() {
        let facts = NoticeFacts(
            recovered: [RecoveredRecording(noteID: note, recoveredAt: Date(timeIntervalSince1970: 10), duration: 1)],
            importFailure: ImportFailureFact(displayName: "b", kind: .tooLarge, at: Date(timeIntervalSince1970: 5)))
        #expect(Notices.library(facts, LibraryFacts(loading: true)).map(\.kind) == [.importTooLarge, .recovered])
    }

    private func produceAll() -> [BannerSpec] {
        var all: [BannerSpec] = []
        var paused = active
        paused.pause = .otherApp
        all += Notices.recording(.active(paused), microphoneOff: true)
        paused.pause = .routeLost
        all += Notices.recording(.active(paused), microphoneOff: false)
        var low = active
        low.warning = .lowStorage(minutesLeft: 10)
        all += Notices.recording(.active(low), microphoneOff: false)
        for outcome in [RecordingOutcome.stoppedForSpace, .microphoneFailed, .couldNotStart] {
            all += Notices.recording(.idle, microphoneOff: false, ended: outcome)
        }
        all += Notices.library(NoticeFacts(
            recovered: [RecoveredRecording(noteID: note, recoveredAt: .distantPast, duration: 1)],
            compressionFailedAt: .distantPast, unreadableNotes: 1, queueHold: .user, waitingJobs: 2, jobRunning: true,
            consented: false, importing: ["x"], notificationsOff: true), LibraryFacts(liveNotes: 0, audioOnly: true))
        all += Notices.library(NoticeFacts(), LibraryFacts(liveNotes: 1, query: "q", results: 0))
        all += Notices.library(NoticeFacts(), LibraryFacts(unavailable: true))
        for failure in [ImportFailureKind.tooLarge, .noSpace(bytesNeeded: 1), .cannotOpen] {
            all += Notices.library(NoticeFacts(importFailure: ImportFailureFact(displayName: "x", kind: failure, at: .distantPast)),
                                   LibraryFacts())
        }
        all += Notices.settings(NoticeFacts(voicesUnavailable: true))
        all += Notices.job(job(.paused, doneMs: 1))
        all += Notices.job(job(.paused))
        all += Notices.job(job(.failed, failure: .checkpointMismatch))
        all += Notices.job(job(.failed, failure: .audio))
        all += Notices.job(nil, oneVoice: true)
        all.append(Notices.downloading(DownloadFact(part: .speech, fraction: 0.5, at: .distantPast)))
        all += DownloadError.allCases.map { Notices.download($0) }
        // No standalone install verifies files on iOS (Apple installs its speech assets): the checking banner is the
        // catalogue's only.
        all.append(BannerSpec(.dlChecking, BannerArgs(percent: 80)))
        return all
    }
}

@Suite struct BannerKindTests {
    // ports: BannerKindTest#flagsTonesAndGroups
    @Test func flagsTonesAndGroups() {
        #expect(Set(BannerKind.allCases.filter { !$0.appEmitted }) == [.txCalculating, .txBattery])
        #expect(Set(BannerKind.allCases.filter(\.dismissible)) == [.recovered, .recCompressionFailed, .notesUnreadable])
        let counts = Dictionary(grouping: BannerKind.allCases, by: \.group).mapValues(\.count)
        // Android's groups less NO_ENCODER, TX_MEMORY, IMPORT_WAV and REC_STOPPED_FILE_LIMIT, plus the iOS kinds.
        #expect(counts == [.trust: 7, .recording: 9, .transcription: 8, .download: 8, .library: 10])
        #expect(BannerKind.allCases.allSatisfy { $0.actions.count <= 2 })
        #expect(BannerKind.trustVerified.tone == .ok)
        #expect(BannerKind.libNoMatch.tone == .plain)
        #expect(BannerKind.recovered.tone == .info)
        #expect(BannerKind.txFailed.tone == .error)
        #expect(BannerKind.txQueueHeld.tone == .warn)
        #expect(Set(BannerKind.allCases.filter(\.iOSOnly)) == [.recInputLost, .recCompressionFailed, .notesUnreadable])
    }

    // ports: BannerKindTest#specDefaultsComeFromTheKind
    @Test func specDefaultsComeFromTheKind() {
        let spec = BannerSpec(.recovered, BannerArgs(count: 1))
        #expect(spec.actions == [.open])
        #expect(spec.dismissible)
        #expect(!spec.announce)
        #expect(spec.id == "RECOVERED")
        #expect(!BannerSpec(.txFailed).dismissible)
        #expect(BannerSpec(.txFailed, dismissible: true, id: "n1").id == "n1")
    }

    @Test func theDownloadPercentComesFromTheBytesWhenItIsNotGiven() {
        #expect(BannerArgs(percent: 46).downloadPercent == 46)
        #expect(BannerArgs(bytes: 31, bytes2: 62).downloadPercent == 50)
        #expect(BannerArgs(bytes: 90, bytes2: 62).downloadPercent == 100)
        #expect(BannerArgs().downloadPercent == 0)
    }
}
