import UIKit
import Observation
import CassiniEngine
import CassiniNotebook

/// The banners of the Library and Settings, as the screens use them: the lists come from `NoticeCenter`, and the
/// actions on them are carried out here (Android `LibraryViewModel.bannerAction`).
@MainActor @Observable final class NoticesStore {
    let center: NoticeCenter
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let recording: RecordingStore

    init(center: NoticeCenter, router: Router, processing: ProcessingStore, recording: RecordingStore) {
        self.center = center; self.router = router; self.processing = processing; self.recording = recording
    }

    func library(_ facts: LibraryFacts) -> [BannerSpec] { center.library(facts) }
    var settingsBanners: [BannerSpec] { center.settingsBanners }

    func dismiss(_ spec: BannerSpec) { center.dismiss(spec.kind) }

    /// A banner button of the Library or Settings. `chooseFile` opens the file picker.
    func perform(_ action: BannerAction, on spec: BannerSpec, chooseFile: () -> Void = {}) {
        let kind = spec.kind
        switch action {
        case .continue:
            processing.continueQueue()
        case .open:
            guard let latest = center.latestRecovered else { return }
            center.dismiss(.recovered)
            router.openNote(latest.noteID)
        case .download:
            router.show(.modelDownload(noteID: nil))
        case .retry, .downloadAgain:
            processing.retryInstall()
        case .tryAgain where kind.group == .download:
            processing.retryInstall()
        case .tryAgain, .chooseAnother, .import:
            center.dismiss(kind)
            chooseFile()
        case .turnOn:
            Self.openNotificationSettings()
        case .record:
            Task { await recording.start() }
        case .resume, .startOver, .transcribe, .transcribeAgain, .playAnyway, .openNote, .openSettings, .cancel:
            // The Note and Recording screens' own actions; never on a Library or Settings banner.
            break
        }
    }

    /// Cassini's notification settings in the Settings app.
    static func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }
}
