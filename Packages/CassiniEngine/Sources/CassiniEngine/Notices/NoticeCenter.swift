import Foundation
import Observation
import CassiniNotebook

/// Merges what the coordinators know (the queue, the recorder's recovery, the imports, the downloads, the library and
/// the saved voices) with the notification permission and the model consent into one `NoticeFacts` (Android
/// `NoticeCenter`). The screens turn it into their banner lists with `Notices`, so no notice replaces another.
///
/// Each source registers a contributor that adds its facts, and a handler for the banners the user closes. The
/// center remembers what the user closed where Android does: RECOVERED in `notices.recoveredAck` (it never goes
/// back), an import error until the next import and a download failure until the next install (their sources clear
/// them), and the iOS-only lasting notices for this run.
@MainActor @Observable public final class NoticeCenter {
    public typealias Contributor = @MainActor (inout NoticeFacts) -> Void
    public typealias DismissHandler = @MainActor (BannerKind) -> Void

    /// The app may not post notifications: the user turned them off.
    public private(set) var notificationsOff = false
    /// The speech model is installed for the speech language, which counts as consent.
    private var speechReady = false
    /// Lasting notices closed in this run.
    private var closed: Set<BannerKind> = []

    @ObservationIgnored private var contributors: [Contributor] = []
    @ObservationIgnored private var dismissHandlers: [DismissHandler] = []
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let speechModelReady: @MainActor () async -> Bool

    /// `speechModelReady` answers whether the speech model is installed for the speech language.
    public init(settings: SettingsStore, notifier: any Notifier, speechModelReady: @escaping @MainActor () async -> Bool) {
        self.settings = settings
        self.notifier = notifier
        self.speechModelReady = speechModelReady
    }

    /// Adds a source: `contribute` adds its facts each time they are read, `dismiss` hears every banner closed.
    public func register(_ contribute: @escaping Contributor, dismiss: DismissHandler? = nil) {
        contributors.append(contribute)
        if let dismiss { dismissHandlers.append(dismiss) }
    }

    /// Every fact the banners need. Reading it inside a view body observes each source it reads.
    public var facts: NoticeFacts {
        var facts = NoticeFacts()
        for contribute in contributors { contribute(&facts) }
        if let ack = settings.recoveredAck { facts.recovered.removeAll { $0.recoveredAt <= ack } }
        if closed.contains(.notesUnreadable) { facts.unreadableNotes = 0 }
        facts.consented = settings.modelsConsentAt != nil || speechReady
        facts.notificationsOff = notificationsOff
        return facts
    }

    public func library(_ library: LibraryFacts) -> [BannerSpec] { Notices.library(facts, library) }
    public var settingsBanners: [BannerSpec] { Notices.settings(facts) }

    /// Reads the notification permission and the speech model again: at launch and each time Cassini comes back to
    /// the screen, as the user may have changed them in Settings.
    public func refresh() async {
        notificationsOff = await notifier.authorizationStatus() == .denied
        speechReady = await speechModelReady()
    }

    /// Asks for permission to notify the first time the user records, transcribes or downloads, and only then.
    public func askNotificationsOnce() async {
        guard !settings.notificationsAsked else { return }
        settings.markNotificationsAsked()
        await notifier.requestOnce()
        notificationsOff = await notifier.authorizationStatus() == .denied
    }

    /// The user closed the banner of `kind`, or acted on it in a way that ends it.
    public func dismiss(_ kind: BannerKind) {
        switch kind {
        case .recovered:
            // The moment of recovery, not of recording, so the acknowledgement only moves forward and a later launch's
            // recovery shows again.
            if let latest = facts.recovered.map(\.recoveredAt).max() { settings.acknowledgeRecovered(upTo: latest) }
        case .notesUnreadable:
            closed.insert(kind)
        default:
            break
        }
        for handler in dismissHandlers { handler(kind) }
    }

    /// The latest recorded of the recovered recordings, which the RECOVERED banner opens; nil when the banner is not
    /// shown.
    public var latestRecovered: RecoveredRecording? { facts.latestRecovered }
}

extension BannerKind {
    /// The import errors, closed until the next import.
    public var isImportFailure: Bool { [.importTooLarge, .importNoSpace, .importOpen].contains(self) }
    /// The download failures, closed until the next install.
    public var isDownloadFailure: Bool {
        [.dlNoConnection, .dlStopped, .dlNoSpace, .dlFileCheck, .dlInstallFailed].contains(self)
    }
}
