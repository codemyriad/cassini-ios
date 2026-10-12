import Foundation
import CassiniNotebook

/// The Note screen's transcription and download banners, what their buttons ask for and what closing one does
/// (Android `NoteViewModel.banners`, `bannerAction` and `dismissBanner`). The screen keeps the ids it closed and
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

    /// The banners of `note` and its `job`, less the ids closed on the screen. `failureText` gives a failed job's
    /// message.
    public static func banners(_ note: Note, job: Job?, failureText: (JobFailure) -> String,
                               dismissed: Set<String> = []) -> [BannerSpec] {
        Notices.job(job, oneVoice: oneVoice(note), failureText: job?.failure.map(failureText),
                    requiredFreeBytes: downloadFreeBytes, noNewVersion: note.refusesNewVersion)
            .filter { !dismissed.contains($0.id) }
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
