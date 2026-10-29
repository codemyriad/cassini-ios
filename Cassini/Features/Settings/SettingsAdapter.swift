import Foundation
import Observation
import CassiniEngine
import CassiniInference
import CassiniNotebook

/// `SettingsPorts` over the app's stores. Its properties read observable stores, so the Settings screen follows them.
@MainActor @Observable final class SettingsAdapter: SettingsPorts {
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let voicesStore: VoicesStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let notices: NoticeCenter
    @ObservationIgnored private let transcriber: any Transcribing

    init(settings: SettingsStore, library: LibraryStore, voices: VoicesStore, processing: ProcessingStore,
         notices: NoticeCenter, transcriber: any Transcribing) {
        self.settings = settings; self.library = library; self.voicesStore = voices; self.processing = processing
        self.notices = notices; self.transcriber = transcriber
    }

    /// The stored status of each part, with the standalone install and the running job's model download over it.
    var modelStatuses: [ModelPart: ModelPartStatus] { processing.models.statuses }

    func consented(to part: ModelPart) -> Bool {
        part == .speech ? settings.downloadsAllowed : settings.speakerDownloadsAllowed
    }

    func size(of part: ModelPart) -> ModelSize {
        switch part {
        case .speech: .managedBySystem
        // The diarizer and CAM++ download together: their bytes over the network.
        case .speakers: .bytes(ModelCatalog.speakerBytes + ModelCatalog.voiceprintBytes)
        case .voices: .includedWith(.speakers)
        }
    }

    func refreshModels() async { await processing.models.refresh() }

    func speechLanguages() async -> [SpeechLanguage] { await transcriber.speechLanguages() }

    var voices: Int { voicesStore.savedVoices.count }
    var trash: Int { library.notes.count { $0.trashedAt != nil } }
    var notes: [Note] { library.notes }

    /// The notification permission as `NoticeCenter` last read it, so Settings and the banners agree.
    var notificationsOff: Bool { notices.facts.notificationsOff }
    func refreshNotices() async { await notices.refresh() }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}
