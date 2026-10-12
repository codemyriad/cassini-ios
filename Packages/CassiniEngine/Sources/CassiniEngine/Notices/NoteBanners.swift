import Foundation
import CassiniNotebook

/// The Note screen's audio, transcription and download banners, what their buttons ask for and what closing one does
/// (Android `NoteViewModel.banners`, `bannerAction` and `dismissBanner`). The trust banner is `DocumentTrust`'s. The screen keeps the ids it closed and
/// carries out the commands; the rules are here.
public enum NoteBanners {
    /// What a banner button asks the screen to do.
    public enum Command: Hashable, Sendable {
        /// Transcribe with this kind: Resume, Try again, Retry and Download again keep the job's kind.
        case transcribe(JobKind)
        /// Start over, after the screen asks ("Start over? The draft so far is discarded.").
        case confirmStartOver
    }

    /// What closing a banner does.
    public enum Dismissal: Hashable, Sendable {
        /// A final failure goes with its job, so the note shows as it was.
        case clearJob
        /// Any other banner is closed on this screen.
        case hide(id: String)
    }

    /// The free space a failed model download asks for: a job downloads only the speech model, and iOS does not tell
    /// an asset's size before it is downloaded, so this is the plan's estimate (never 0).
    public static let downloadFreeBytes = ModelPlan(missing: [.speech]).requiredFreeBytes

    /// A finished transcript whose speakers could not be told apart (Android `NoteMapping.oneVoice`): on iOS, one whose
    /// speaker analysis failed.
    public static func oneVoice(_ note: Note) -> Bool { !note.transcript.isEmpty && note.speakerAnalysisFailure != nil }

    /// A note with audio only (Android `NoteMode.AudioOnly`): audio that can or will play, no transcript (not even a
    /// finished one that found no speech) and no job but one waiting for the speech model.
    public static func audioOnly(_ note: Note, job: Job?) -> Bool {
        if case .unplayable = note.audio { return false }
        guard job == nil || job?.state == .needsConsent else { return false }
        return note.transcript.isEmpty && note.document == nil && note.status != .ready
    }

    /// The banners of `note` and its `job`, less the ids closed on the screen: PLAIN_AUDIO or UNPLAYABLE first, as
    /// Android, then the job's. `failureText` gives a failure's message (a failed job's, and LONG for audio too long
    /// to transcribe); `unplayableText` the body of an unplayable note, nil for the catalogue's ("Cassini closed
    /// before the recording was saved.").
    public static func banners(_ note: Note, job: Job?, failureText: (JobFailure) -> String,
                               unplayableText: (UnplayableReason) -> String? = { _ in nil },
                               dismissed: Set<String> = []) -> [BannerSpec] {
        var specs: [BannerSpec] = []
        if case .unplayable(let reason) = note.audio {
            specs.append(BannerSpec(.unplayable, BannerArgs(text: unplayableText(reason))))
        } else if audioOnly(note, job: job) {
            // Audio longer than one transcription takes says why, and offers no Transcribe; nor does a capture.
            let tooLong = note.duration > Limits.maxTranscribeDuration
            let noTranscribe = note.audio == .live || tooLong
            specs.append(BannerSpec(.plainAudio, BannerArgs(text: tooLong ? failureText(.long) : nil),
                                    actions: noTranscribe ? [] : nil))
        }
        specs += Notices.job(job, oneVoice: oneVoice(note), failureText: job?.failure.map(failureText),
                             requiredFreeBytes: downloadFreeBytes, noNewVersion: note.refusesNewVersion)
        return specs.filter { !dismissed.contains($0.id) }
    }

    /// What `action` on one of the note's banners asks for; nil for an action these banners do not carry, and for
    /// Transcribe again on a note that takes no new version.
    public static func command(for action: BannerAction, note: Note, job: Job?) -> Command? {
        switch action {
        case .resume, .tryAgain, .retry, .downloadAgain: .transcribe(job?.kind ?? .transcribe)
        case .transcribe: .transcribe(.transcribe)
        case .transcribeAgain: note.refusesNewVersion ? nil : .transcribe(.transcribeAgain)
        case .startOver: .confirmStartOver
        default: nil
        }
    }

    /// What closing `spec` does: a final failure clears its job, anything else is hidden on the screen.
    public static func dismissal(of spec: BannerSpec, note: Note, job: Job?) -> Dismissal {
        if spec.kind == .txFailed, let job, Notices.finalFailure(job, noNewVersion: note.refusesNewVersion) {
            return .clearJob
        }
        return .hide(id: spec.id)
    }
}
