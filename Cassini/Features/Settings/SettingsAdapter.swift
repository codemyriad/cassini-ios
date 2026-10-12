import Foundation
import Observation
import UIKit
import CassiniEngine
import CassiniInference
import CassiniNotebook

/// `SettingsPorts` over the app's stores. Its properties read observable stores, so the Settings screen follows them.
@MainActor @Observable final class SettingsAdapter: SettingsPorts {
    private(set) var notificationsOff = false
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let voicesStore: VoicesStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let notifier: any Notifier

    init(settings: SettingsStore, library: LibraryStore, voices: VoicesStore, processing: ProcessingStore,
         notifier: any Notifier) {
        self.settings = settings; self.library = library; self.voicesStore = voices; self.processing = processing
        self.notifier = notifier
    }

    /// The stored status of each part, with the standalone install and the running job's model download over it.
    var modelStatuses: [ModelPart: ModelPartStatus] {
        var statuses: [ModelPart: ModelPartStatus] = [:]
        for part in ModelPart.allCases { statuses[part] = processing.models.status(of: part) }
        if let download = processing.progress.modelDownload {
            let parts: [ModelPart] = download.part == .speech ? [.speech] : [.speakers, .voices]
            for part in parts where statuses[part] != nil { statuses[part] = ModelRows.status(of: download) }
        }
        return statuses
    }

    func consented(to part: ModelPart) -> Bool {
        part == .speech ? settings.downloadsAllowed : settings.speakerDownloadsAllowed
    }

    func size(of part: ModelPart) -> ModelSize {
        switch part {
        case .speech: .managedBySystem
        case .speakers: .bytes(SpeakerAnalyzer.manifest.totalBytes)
        case .voices: .includedWith(.speakers)
        }
    }

    func refreshModels() async { await processing.models.refresh() }

    var voices: Int { voicesStore.savedVoices.count }
    var trash: Int { library.notes.count { $0.trashedAt != nil } }
    var notes: [Note] { library.notes }

    func refreshNotices() async { notificationsOff = await notifier.authorizationStatus() == .denied }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

/// Opens Cassini's notification settings in the Settings app.
@MainActor func openNotificationSettings() {
    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
}
