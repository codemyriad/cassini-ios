import Foundation

/// A banner of the Note screen (Android `BannerKind`'s trust, plain-audio, unplayable and transcription kinds, plus the
/// iOS speaker and playback notices). The app words each kind; the actions are the catalogue's, first filled.
public struct NoteBanner: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case trustVerified, trustNotVerified, trustAudioChanged, trustUnreadable, trustNewerFormat
        case plainAudio, unplayable
        case paused, pausedEarly, queueHeld, oneVoice, checkpointMismatch, memory, failed
        /// iOS: the speaker step found no speakers ("You can assign passages manually").
        case noSpeakers
        /// iOS: the player could not open the file (WP7's `PlaybackState.failed`).
        case playbackFailed
    }

    public enum Action: Hashable, Sendable {
        case playAnyway, transcribe, transcribeAgain, resume, startOver, tryAgain, continueQueue
    }

    public var kind: Kind
    public var actions: [Action]
    /// The failure a `failed` banner words.
    public var failure: JobFailure?
    /// `paused`: where the saved progress ends, of the whole audio.
    public var doneMs: Int64 = 0
    public var totalMs: Int64 = 0
    /// `paused` and `pausedEarly`: iOS stopped the job, not the user.
    public var bySystem = false
    /// `queueHeld`: the waiting jobs.
    public var count = 0
    /// `plainAudio`: the audio is longer than one transcription takes (`Limits.maxTranscribeDuration`).
    public var tooLong = false

    public var id: String { kind.rawValue }

    public init(_ kind: Kind, actions: [Action]? = nil) {
        self.kind = kind
        self.actions = actions ?? kind.actions
    }
}

extension NoteBanner.Kind {
    /// The catalogue actions of the kind.
    public var actions: [NoteBanner.Action] {
        switch self {
        case .trustNotVerified: [.playAnyway]
        case .trustAudioChanged, .trustUnreadable, .oneVoice: [.transcribeAgain]
        case .plainAudio: [.transcribe]
        case .paused: [.resume, .startOver]
        case .pausedEarly: [.resume]
        case .queueHeld: [.continueQueue]
        case .checkpointMismatch: [.startOver]
        case .memory, .failed: [.tryAgain]
        case .trustVerified, .trustNewerFormat, .unplayable, .noSpeakers, .playbackFailed: []
        }
    }

    /// The trust banner of a document's trust.
    public static func trust(_ trust: DocumentTrust) -> NoteBanner.Kind {
        switch trust {
        case .verified: .trustVerified
        case .notVerified: .trustNotVerified
        case .audioChanged: .trustAudioChanged
        case .unreadable: .trustUnreadable
        case .newerFormat: .trustNewerFormat
        }
    }
}

/// What the Note screen's banners are built from, besides the note and its job.
public struct NoteBannerFacts: Hashable, Sendable {
    /// The trust chip was tapped an odd number of times: the trust banner's default is inverted.
    public var trustToggled = false
    public var queueHold: QueueHold?
    /// Queued jobs, not counting the running one.
    public var waitingJobs = 0
    /// This note's player failed to open its file.
    public var playbackFailed = false
    /// Banners dismissed on this screen, by id.
    public var dismissed: Set<String> = []

    public init(trustToggled: Bool = false, queueHold: QueueHold? = nil, waitingJobs: Int = 0, playbackFailed: Bool = false,
                dismissed: Set<String> = []) {
        self.trustToggled = trustToggled; self.queueHold = queueHold; self.waitingJobs = waitingJobs
        self.playbackFailed = playbackFailed; self.dismissed = dismissed
    }
}

public enum NoteBanners {
    /// The banners of `note` in `mode`, in order: plain audio or unplayable, the trust banner over a transcript, the
    /// job's banner, one voice, the held queue below a paused job; then the iOS speaker and playback notices. Dismissed
    /// ones are left out.
    public static func of(_ note: Note, job: Job?, mode: NoteMode, facts: NoteBannerFacts) -> [NoteBanner] {
        var list: [NoteBanner] = []
        switch mode {
        case .audioOnly:
            let tooLong = note.duration > Limits.maxTranscribeDuration
            var plain = NoteBanner(.plainAudio, actions: note.isRecording || tooLong ? [] : nil)
            plain.tooLong = tooLong
            list.append(plain)
        case .unplayable:
            list.append(NoteBanner(.unplayable))
        default:
            break
        }
        if mode.showsReading, let info = note.document, DocumentTrust.showsBanner(info, toggled: facts.trustToggled) {
            list.append(NoteBanner(.trust(DocumentTrust(info.state))))
        }
        let refused = TranscribeAgainRule.refused(note)
        if let job, let banner = jobBanner(job, refused: refused) { list.append(banner) }
        if job == nil, !note.transcript.isEmpty, note.speakerAnalysisFailure == .speakers {
            list.append(NoteBanner(.oneVoice, actions: refused ? [] : nil))
        }
        if case .paused = mode, facts.queueHold != nil, facts.waitingJobs > 0 {
            var held = NoteBanner(.queueHeld)
            held.count = facts.waitingJobs
            list.append(held)
        }
        if job == nil, note.speakerAnalysisFailure == .empty { list.append(NoteBanner(.noSpeakers)) }
        if facts.playbackFailed, mode.hasPlayer { list.append(NoteBanner(.playbackFailed)) }
        var seen = Set<String>()
        return list.filter { !facts.dismissed.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// Whether `job` failed in a way every new try repeats: the document was refused, it cannot take a new version, or
    /// the audio is too long (`LONG`). Its banner offers nothing to try, and dismissing it removes the job.
    public static func finalFailure(_ job: Job, refused: Bool) -> Bool {
        guard job.state == .failed else { return false }
        if case .documentRefused = job.failure { return true }
        return job.failure == .long || (refused && job.kind == .transcribeAgain)
    }

    private static func jobBanner(_ job: Job, refused: Bool) -> NoteBanner? {
        let checkpoint = job.doneMs > 0
        switch job.state {
        case .paused:
            if job.pauseReason == .memory { return NoteBanner(.memory) }
            var banner = NoteBanner(checkpoint ? .paused : .pausedEarly)
            banner.doneMs = job.doneMs
            banner.totalMs = max(job.totalMs ?? job.doneMs, job.doneMs)
            banner.bySystem = job.pauseReason == .system
            return banner
        case .failed:
            switch job.failure {
            case .checkpointMismatch?: return NoteBanner(.checkpointMismatch)
            case .memory?: return NoteBanner(.memory)
            default:
                let final = finalFailure(job, refused: refused)
                var banner = NoteBanner(.failed, actions: final ? [] : checkpoint ? [.tryAgain, .startOver] : nil)
                banner.failure = job.failure
                return banner
            }
        case .queued, .running, .needsConsent:
            return nil
        }
    }
}
