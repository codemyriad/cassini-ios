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
    /// No speech download offer is needed: installed, or unavailable on this platform/locale.
    private var speechReady = false
    private var speechLanguage: String
    /// Lasting notices closed in this run.
    private var closed: Set<BannerKind> = []

    @ObservationIgnored private var contributors: [Contributor] = []
    @ObservationIgnored private var dismissHandlers: [DismissHandler] = []
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let speechModelReady: @MainActor () async -> Bool
    @ObservationIgnored private var languageFollower: Task<Void, Never>?

    /// `speechModelReady` suppresses the speech download offer: installed, or unavailable on this platform/locale.
    /// The resulting notice fact never writes the user's recorded consent.
    public init(settings: SettingsStore, notifier: any Notifier, speechModelReady: @escaping @MainActor () async -> Bool) {
        self.settings = settings
        self.notifier = notifier
        self.speechModelReady = speechModelReady
        speechLanguage = settings.speechLanguage
        let initialLanguage = settings.speechLanguage
        languageFollower = Task { [weak self, settings] in
            var previous = initialLanguage
            for await language in ObservedValues({ settings.speechLanguage }) {
                guard language != previous else { continue }
                previous = language
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    deinit { languageFollower?.cancel() }

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
        // Suppress download offers while the newly selected locale's eligibility is being read.
        facts.consented = settings.modelsConsentAt != nil || speechReady || speechLanguage != settings.speechLanguage
        facts.notificationsOff = notificationsOff
        return facts
    }

    public func library(_ library: LibraryFacts) -> [BannerSpec] { Notices.library(facts, library) }
    public var settingsBanners: [BannerSpec] { Notices.settings(facts) }

    /// Reads the notification permission and the speech model again: at launch and each time Cassini comes back to
    /// the screen, as the user may have changed them in Settings.
    public func refresh() async {
        notificationsOff = await notifier.authorizationStatus() == .denied
        let language = settings.speechLanguage
        let ready = await speechModelReady()
        guard language == settings.speechLanguage else { return }
        speechReady = ready
        speechLanguage = language
    }

    /// Asks for permission to notify the first time the user records, transcribes or downloads, and only then: never
    /// asked before and not decided yet (Android: not granted and never asked). The one place this is asked; the
    /// recording and model download screens call it too, so Settings and the banners follow the answer.
    public func askNotificationsOnce() async {
        guard !settings.notificationsAsked else { return }
        settings.markNotificationsAsked()
        if await notifier.authorizationStatus() == .notDetermined { await notifier.requestOnce() }
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
        [.dlNoConnection, .dlStopped, .dlNoSpace, .dlFileCheck, .dlInstallFailed, .dlPinUnavailable].contains(self)
    }
}
