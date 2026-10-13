import Foundation

/// The banner lists of each screen as pure functions of `NoticeFacts` and the screen's own facts (Android `Notices`).
/// Each list is ordered failed, attention, info, then fine and plain; within one tone the newest notice comes first,
/// and notices without a time keep the order below. A list never holds two banners with one id.
///
/// The trust, plain-audio and unplayable banners of the Note screen are the Note screen's own; `job` gives its
/// transcription and download banners.
public enum Notices {
    /// A banner and the time of its event, for the order inside a tone.
    private struct Notice {
        var spec: BannerSpec
        var at: Date?
    }

    // MARK: Library

    /// The Library banners: the app-wide notices, then the empty, no-match and unavailable states.
    public static func library(_ facts: NoticeFacts, _ library: LibraryFacts) -> [BannerSpec] {
        var notices: [Notice] = []
        if facts.queueHold != nil, facts.waitingJobs > 0 {
            notices.append(Notice(spec: BannerSpec(.txQueueHeld, BannerArgs(count: facts.waitingJobs))))
        }
        if let latest = facts.latestRecovered {
            let args = BannerArgs(count: facts.recovered.count, ms1: milliseconds(latest.duration))
            let at = facts.recovered.map(\.recoveredAt).max()
            notices.append(Notice(spec: BannerSpec(.recovered, args, announce: true), at: at))
        }
        if let failedAt = facts.compressionFailedAt {
            notices.append(Notice(spec: BannerSpec(.recCompressionFailed, announce: true), at: failedAt))
        }
        if !facts.consented, library.audioOnly { notices.append(Notice(spec: BannerSpec(.dlRecordNow))) }
        if let download = facts.download, let error = download.failure {
            notices.append(Notice(spec: self.download(error, requiredFreeBytes: download.requiredFreeBytes, announce: true),
                                  at: download.at))
        }
        if facts.notificationsOff, facts.jobRunning { notices.append(Notice(spec: BannerSpec(.notificationsOff))) }
        if facts.unreadableNotes > 0 {
            notices.append(Notice(spec: BannerSpec(.notesUnreadable, BannerArgs(count: facts.unreadableNotes))))
        }
        notices += imports(facts)
        if !library.loading { notices += listState(library, unavailable: facts.libraryUnavailable) }
        return ordered(notices)
    }

    private static func imports(_ facts: NoticeFacts) -> [Notice] {
        var notices: [Notice] = []
        if let name = facts.importing.last {
            notices.append(Notice(spec: BannerSpec(.importing, BannerArgs(text: name), announce: true)))
        }
        if let failure = facts.importFailure {
            let kind: BannerKind, bytes: Int64
            switch failure.kind {
            case .tooLarge: (kind, bytes) = (.importTooLarge, 0)
            case .noSpace(let needed): (kind, bytes) = (.importNoSpace, needed)
            case .cannotOpen, .cannotSave: (kind, bytes) = (.importOpen, 0)
            }
            // Shown until dismissed or the next import, so every import error has a close.
            let spec = BannerSpec(kind, BannerArgs(bytes: bytes), announce: true, dismissible: true)
            notices.append(Notice(spec: spec, at: failure.at))
        }
        return notices
    }

    private static func listState(_ library: LibraryFacts, unavailable: Bool) -> [Notice] {
        let query = library.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if library.unavailable || unavailable { return [Notice(spec: BannerSpec(.libUnavailable, announce: true))] }
        if !query.isEmpty, library.results == 0 { return [Notice(spec: BannerSpec(.libNoMatch, BannerArgs(text: query)))] }
        if query.isEmpty, library.liveNotes == 0 { return [Notice(spec: BannerSpec(.libEmpty))] }
        return []
    }

    // MARK: Recording

    /// The Recording screen's banners for the recorder `state`. `microphoneOff` is true while microphone access is
    /// denied; `ended` is the outcome the screen still shows after the capture ended (the recorder may be idle again).
    public static func recording(_ state: RecordingState, microphoneOff: Bool, ended: RecordingOutcome? = nil) -> [BannerSpec] {
        let banners = RecordingBanner.banners(state: state, microphoneOff: microphoneOff, ended: ended)
        return ordered(banners.map { Notice(spec: spec($0)) })
    }

    /// The catalogue banner of a Recording screen banner.
    public static func spec(_ banner: RecordingBanner) -> BannerSpec {
        switch banner {
        case .microphoneOff: BannerSpec(.recMicOff)
        case .couldNotStart: BannerSpec(.recCouldNotStart, announce: true)
        case .microphoneFailed: BannerSpec(.recMicFailed, announce: true)
        case .stoppedForSpace: BannerSpec(.recStoppedStorage, BannerArgs(bytes: Limits.minRecordingFreeBytes), announce: true)
        case .pausedByOtherApp: BannerSpec(.recPausedOtherApp, announce: true)
        case .inputLost: BannerSpec(.recInputLost, announce: true)
        case .storageLow(let minutes): BannerSpec(.recStorageLow, BannerArgs(ms1: Int64(minutes) * 60_000), announce: true)
        }
    }

    // MARK: Transcription and download of one note

    /// The banners of one note's `job`: paused, failed and download failures. `oneVoice` is true when the speakers of
    /// a finished transcript could not be told apart; `failureText` is the message of a failed job's code;
    /// `requiredFreeBytes` the free space a model download asks for. `noNewVersion` is true when the note cannot take
    /// a new transcript: then no banner offers Transcribe again, and a failed Transcribe again offers no Try again.
    public static func job(_ job: Job?, oneVoice: Bool = false, failureText: String? = nil, requiredFreeBytes: Int64 = 0,
                           noNewVersion: Bool = false) -> [BannerSpec] {
        var notices: [Notice] = []
        if let job, let spec = jobBanner(job, failureText: failureText, requiredFreeBytes: requiredFreeBytes,
                                         noNewVersion: noNewVersion) {
            notices.append(Notice(spec: spec, at: job.updatedAt))
        }
        if oneVoice, job == nil {
            notices.append(Notice(spec: BannerSpec(.txOneVoice, actions: noNewVersion ? [] : BannerKind.txOneVoice.actions)))
        }
        return ordered(notices)
    }

    private static func jobBanner(_ job: Job, failureText: String?, requiredFreeBytes: Int64,
                                  noNewVersion: Bool) -> BannerSpec? {
        let checkpoint = job.doneMs > 0
        switch job.state {
        case .paused:
            let bySystem = job.pauseReason == .system
            guard checkpoint else { return BannerSpec(.txPausedEarly, BannerArgs(bySystem: bySystem)) }
            return BannerSpec(.txPaused, BannerArgs(ms1: job.doneMs, ms2: max(job.totalMs ?? 0, job.doneMs), bySystem: bySystem))
        case .failed:
            let failure = job.failure ?? .unknown
            if case .download(let error) = failure { return download(error, requiredFreeBytes: requiredFreeBytes) }
            if failure == .checkpointMismatch { return BannerSpec(.txCheckpointMismatch) }
            let final = finalFailure(job, noNewVersion: noNewVersion)
            // A final failure has nothing to try, so the user can dismiss it.
            let actions: [BannerAction] = final ? [] : checkpoint ? [.tryAgain, .startOver] : BannerKind.txFailed.actions
            return BannerSpec(.txFailed, BannerArgs(text: failureText), actions: actions, dismissible: final)
        case .queued, .running, .needsConsent:
            return nil
        }
    }

    /// Whether `job` failed in a way every new try repeats: the document was refused, it cannot take a new version, or
    /// the recording is too long to transcribe. Its banner offers no Try again and no Start over, and its dismissal
    /// removes the job.
    public static func finalFailure(_ job: Job, noNewVersion: Bool) -> Bool {
        guard job.state == .failed else { return false }
        switch job.failure {
        case .documentRefused, .long: return true
        default: return noNewVersion && job.kind == .transcribeAgain
        }
    }

    // MARK: Model download

    /// DL_DOWNLOADING (with Cancel) or, while the files are checked, DL_CHECKING: the download row of the processing
    /// card (Android `Notices.downloading`). Apple's speech assets report a fraction, so their bytes are left out; a
    /// check without a count of the files checked has no percentage.
    public static func downloading(_ progress: DownloadProgress) -> BannerSpec {
        if progress.verifying {
            return BannerSpec(.dlChecking, BannerArgs(percent: progress.totalBytes > 0 ? progress.percent : nil))
        }
        return BannerSpec(.dlDownloading, BannerArgs(bytes: progress.doneBytes, bytes2: progress.totalBytes,
                                                     percent: progress.percent, part: progress.part))
    }

    /// The Settings banner of a standalone install that runs, with Cancel (iOS only: the model download screen closes
    /// once the download starts); nil once it failed. The Library shows only its failure, as Android.
    public static func downloading(_ download: DownloadFact) -> BannerSpec? {
        guard download.failure == nil else { return nil }
        if download.checking { return BannerSpec(.dlChecking) }
        let percent = Int((min(max(download.fraction ?? 0, 0), 1) * 100).rounded(.down))
        return BannerSpec(.dlDownloading, BannerArgs(percent: percent, part: download.part))
    }

    /// The failure banner of a model download's `error`.
    public static func download(_ error: DownloadError, requiredFreeBytes: Int64 = 0, announce: Bool = false) -> BannerSpec {
        switch error {
        case .noConnection: BannerSpec(.dlNoConnection, announce: announce)
        case .interrupted, .hostNotAllowed: BannerSpec(.dlStopped, announce: announce)
        case .stoppedBySystem: BannerSpec(.dlStopped, BannerArgs(bySystem: true), announce: announce)
        case .notEnoughStorage: BannerSpec(.dlNoSpace, BannerArgs(bytes: requiredFreeBytes), announce: announce)
        case .fileCheckFailed: BannerSpec(.dlFileCheck, announce: announce)
        case .install: BannerSpec(.dlInstallFailed, announce: announce)
        }
    }

    // MARK: Settings

    /// Settings: "Notifications are off" whenever they are; "Saved voices can't be read" for an unreadable file; the
    /// standalone install that runs.
    public static func settings(_ facts: NoticeFacts) -> [BannerSpec] {
        var notices: [Notice] = []
        if facts.notificationsOff { notices.append(Notice(spec: BannerSpec(.notificationsOff))) }
        if facts.voicesUnavailable { notices.append(Notice(spec: BannerSpec(.voicesUnreadable))) }
        if let download = facts.download.flatMap(downloading) { notices.append(Notice(spec: download)) }
        return ordered(notices)
    }

    // MARK: Order

    /// The place of `tone` in a list: failed, attention, info, then the fine and plain tones together.
    public static func rank(_ tone: BannerTone) -> Int {
        switch tone {
        case .error: 0
        case .warn: 1
        case .info: 2
        case .ok, .plain: 3
        }
    }

    /// Failed, attention, info, then fine and plain; newest first within a tone; the rest keep their order. The first
    /// banner of each id stays.
    private static func ordered(_ notices: [Notice]) -> [BannerSpec] {
        let sorted = notices.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element, rhs.element)
            let (leftRank, rightRank) = (rank(left.spec.kind.tone), rank(right.spec.kind.tone))
            if leftRank != rightRank { return leftRank < rightRank }
            let (leftAt, rightAt) = (left.at ?? .distantPast, right.at ?? .distantPast)
            if leftAt != rightAt { return leftAt > rightAt }
            return lhs.offset < rhs.offset
        }
        var seen: Set<String> = []
        return sorted.map(\.element.spec).filter { seen.insert($0.id).inserted }
    }

    private static func milliseconds(_ duration: TimeInterval) -> Int64 { Int64((max(duration, 0) * 1000).rounded()) }
}
