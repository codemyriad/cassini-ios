import Foundation
import CassiniNotebook

/// The Note screen's catalogue banners for its mode (Android `NoteViewModel.banners`): plain audio or unplayable, the
/// trust banner over the reading content, the job's transcription and download banners, one voice, and the held queue
/// below a paused job. What their buttons ask for and what closing one does is `NoteScreenState`'s.
public enum NoteBanners {
    /// The free space a failed model download asks for when the facts give none: a transcription downloads only the
    /// speech model, and iOS does not tell an Apple asset's size before it is downloaded, so this is the plan's
    /// estimate (never 0). Parakeet's figure, and the speaker models' of an Identify speakers, come with the facts
    /// (`NoteBannerFacts`).
    public static let downloadFreeBytes = ModelDownloadPlan.speechInstallBytes

    /// A finished transcript whose speakers could not be told apart (Android `NoteMapping.oneVoice`): on iOS, one whose
    /// speaker step failed. A speaker step that found nobody is `noSpeakers`.
    public static func oneVoice(_ note: Note) -> Bool {
        guard !note.transcript.isEmpty, let failure = note.speakerAnalysisFailure else { return false }
        return failure != .empty
    }

    /// iOS: the speaker step found no speakers ("You can assign passages manually"); not a catalogue banner.
    public static func noSpeakers(_ note: Note, job: Job?) -> Bool { job == nil && note.speakerAnalysisFailure == .empty }

    /// The speaker row is unknown until the asynchronous availability read publishes. Keep the download action
    /// disabled during that read, downloading and verification, instead of briefly offering speech transcription.
    public static func speakerDownloadState(_ status: ModelPartStatus?) -> (missing: Bool, installing: Bool) {
        switch status {
        case .notDownloaded, .failed: (true, false)
        case nil, .checking, .downloading: (false, true)
        case .ready, .unsupported: (false, false)
        }
    }

    /// The banners of `note` in `mode`, less the ids closed on the screen, in Android's order. `failureText` gives a
    /// failure's message (a failed job's, and LONG for audio too long to transcribe); `unplayableText` the body of an
    /// unplayable note, nil for the catalogue's ("Cassini closed before the recording was saved.").
    public static func banners(_ note: Note, job: Job?, mode: NoteMode, facts: NoteBannerFacts = NoteBannerFacts(),
                               failureText: (JobFailure) -> String,
                               unplayableText: (UnplayableReason) -> String? = { _ in nil }) -> [BannerSpec] {
        var specs: [BannerSpec] = []
        switch mode {
        case .audioOnly:
            // Audio longer than one transcription takes says why, and offers no Transcribe; nor does a capture.
            let tooLong = note.duration > Limits.maxTranscribeDuration
            let noTranscribe = note.audio == .live || tooLong
            specs.append(BannerSpec(.plainAudio, BannerArgs(text: tooLong ? failureText(.long) : facts.speechUnavailableText),
                                    actions: noTranscribe ? [] : nil,
                                    disabledActions: facts.speechUnavailableText == nil ? [] : [.transcribe]))
        case .unplayable:
            if case .unplayable(let reason) = note.audio {
                specs.append(BannerSpec(.unplayable, BannerArgs(text: unplayableText(reason))))
            }
        default:
            break
        }
        if mode.showsReading, let trust = trustBanner(note, toggled: facts.trustToggled) { specs.append(trust) }
        var jobBanners = Notices.job(job, oneVoice: oneVoice(note), failureText: job?.failure.map(failureText),
                             requiredFreeBytes: (job?.kind == .speakersOnly ? facts.speakersInstallBytes
                                                 : facts.speechInstallBytes) ?? downloadFreeBytes,
                             noNewVersion: note.refusesNewVersion)
        if facts.speakerModelsMissing || facts.speakerModelsInstalling {
            for index in jobBanners.indices where jobBanners[index].kind == .txOneVoice {
                jobBanners[index].actions = ReadOnlyReason.of(note, job: job) == nil ? [.download] : []
                if facts.speakerModelsInstalling { jobBanners[index].disabledActions.insert(.download) }
            }
        }
        specs += jobBanners
        if case .paused = mode, facts.queueHold != nil, facts.waitingJobs > 0 {
            specs.append(BannerSpec(.txQueueHeld, BannerArgs(count: facts.waitingJobs)))
        }
        var seen = Set<String>()
        return specs.filter { !facts.dismissed.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// The trust banner of a note from a Cassini document: by default every state but verified, not verified only
    /// until Play anyway; the chip inverts that. A document that takes no new version offers no Transcribe again.
    private static func trustBanner(_ note: Note, toggled: Bool) -> BannerSpec? {
        guard let info = note.document, DocumentTrust.showsBanner(info, toggled: toggled) else { return nil }
        let kind = BannerKind.trust(DocumentTrust(info.state))
        let actions = note.refusesNewVersion ? kind.actions.filter { $0 != .transcribeAgain } : kind.actions
        return BannerSpec(kind, actions: actions)
    }
}
