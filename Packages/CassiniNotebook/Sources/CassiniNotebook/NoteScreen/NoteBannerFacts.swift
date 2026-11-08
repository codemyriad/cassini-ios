import Foundation

/// What the Note screen's banners are built from, besides the note, its job and its mode (Android `NoticeFacts` and
/// the screen's own state). The rules are CassiniEngine's `NoteBanners`.
public struct NoteBannerFacts: Hashable, Sendable {
    /// The trust chip was tapped an odd number of times: the trust banner's default is inverted.
    public var trustToggled = false
    public var queueHold: QueueHold?
    /// Queued jobs, not counting the running one.
    public var waitingJobs = 0
    /// Banners closed on this screen, by id.
    public var dismissed: Set<String> = []
    /// The free space the speech model's install asks for ("Free about N MB" of a transcription's failed download);
    /// nil for the estimate of Apple's assets.
    public var speechInstallBytes: Int64?
    /// The free space the speaker models' install asks for ("Free about N MB" of a failed Identify speakers).
    public var speakersInstallBytes: Int64?
    /// A known unavailable device/locale/model, separately from missing downloadable assets.
    public var speechUnavailableText: String?

    public init(trustToggled: Bool = false, queueHold: QueueHold? = nil, waitingJobs: Int = 0,
                dismissed: Set<String> = [], speechInstallBytes: Int64? = nil, speakersInstallBytes: Int64? = nil, speechUnavailableText: String? = nil) {
        self.trustToggled = trustToggled; self.queueHold = queueHold; self.waitingJobs = waitingJobs
        self.dismissed = dismissed; self.speechInstallBytes = speechInstallBytes
        self.speakersInstallBytes = speakersInstallBytes; self.speechUnavailableText = speechUnavailableText
    }
}

extension BannerKind {
    /// The trust banner of a document's trust (Android `NoteViewModel.trustBanner`).
    public static func trust(_ trust: DocumentTrust) -> BannerKind {
        switch trust {
        case .verified: .trustVerified
        case .notVerified: .trustNotVerified
        case .audioChanged: .trustAudioChanged
        case .unreadable: .trustUnreadable
        case .newerFormat: .trustNewerFormat
        }
    }
}
