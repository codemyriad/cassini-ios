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

    public init(trustToggled: Bool = false, queueHold: QueueHold? = nil, waitingJobs: Int = 0,
                dismissed: Set<String> = []) {
        self.trustToggled = trustToggled; self.queueHold = queueHold; self.waitingJobs = waitingJobs
        self.dismissed = dismissed
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
