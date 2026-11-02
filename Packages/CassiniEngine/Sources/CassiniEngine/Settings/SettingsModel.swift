import Foundation
import Observation
import CassiniNotebook

/// What the Settings screen reads and changes. The app binds it to its stores, so the properties are observed through
/// them; tests pass a fake.
@MainActor public protocol SettingsPorts: AnyObject {
    /// The status of each model part, live (installs and a running job's download included); a part not read yet is
    /// missing.
    var modelStatuses: [ModelPart: ModelPartStatus] { get }
    /// Whether the user agreed to download `part`'s models.
    func consented(to part: ModelPart) -> Bool
    func size(of part: ModelPart) -> ModelSize
    /// Reads the installed models again.
    func refreshModels() async
    /// The languages of speech on offer, each marked when its assets are installed.
    func speechLanguages() async -> [SpeechLanguage]
    /// The recognizer this device transcribes with.
    var recognizer: SpeechRecognizer { get }
    /// Saved voices.
    var voices: Int { get }
    /// Notes in Recently Deleted.
    var trash: Int { get }
    /// Every note, Recently Deleted included; the totals leave those out.
    var notes: [Note] { get }
    /// Notifications are turned off for Cassini.
    var notificationsOff: Bool { get }
    /// Reads the notification permission again.
    func refreshNotices() async
    /// `CFBundleShortVersionString`.
    var version: String { get }
}

/// Settings: the model rows, the counts of the Privacy rows, the library totals, the version and the
/// notifications-off banner; each row's tap is an `Effect` for the screen to carry out.
@MainActor @Observable public final class SettingsModel {
    public enum Effect: Hashable, Sendable {
        case open(Route)
        /// Cassini's notification settings ("Turn on").
        case openNotificationSettings
        /// Cassini's page in the Settings app, where iOS sets its language.
        case openAppLanguageSettings
    }

    /// The Your library totals: notes outside Recently Deleted, and their audio.
    public struct LibraryTotals: Hashable, Sendable {
        public var notes: Int
        public var duration: TimeInterval
        public init(notes: Int, duration: TimeInterval) { self.notes = notes; self.duration = duration }
    }

    /// The languages of speech on offer, as last read; empty until the screen appears.
    public private(set) var speechLanguages: [SpeechLanguage] = []

    @ObservationIgnored private let ports: any SettingsPorts
    @ObservationIgnored public var onEffect: (Effect) -> Void = { _ in }

    public init(ports: any SettingsPorts) {
        self.ports = ports
    }

    /// The On-device models rows, in `ModelPart` order.
    public var models: [ModelRow] {
        ModelRows.rows(ports.modelStatuses, consented: ports.consented(to:), size: ports.size(of:))
    }

    public var voices: Int { ports.voices }
    public var trash: Int { ports.trash }
    public var version: String { ports.version }
    public var notificationsOff: Bool { ports.notificationsOff }
    public var library: LibraryTotals { Self.totals(of: ports.notes) }

    /// The screen is shown: the models, the languages and the notification permission are read again.
    public func appeared() async {
        await ports.refreshNotices()
        await ports.refreshModels()
        speechLanguages = await ports.speechLanguages()
    }

    /// Cassini is back on the screen: the notification permission may have changed in the Settings app, and models
    /// may have been installed or removed meanwhile.
    public func resumed() async {
        await ports.refreshNotices()
        await ports.refreshModels()
        speechLanguages = await ports.speechLanguages()
    }

    /// Whether Transcription shows the Speech language picker: only Apple Speech takes a language (its models are per
    /// language); Parakeet hears it, so a Parakeet device has no picker, as Android has none.
    public var showsSpeechLanguage: Bool { ports.recognizer.usesLanguage }

    /// The Speech language picker's entries: the languages on offer sorted by `name`, preceded by the chosen one when
    /// it is not on offer (the picker never drops it). An entry whose assets are on the device shows "· Installed".
    public func languageOptions(chosen: String, name: (String) -> String) -> [SpeechLanguage] {
        Self.languageOptions(speechLanguages, chosen: chosen, name: name)
    }

    public nonisolated static func languageOptions(_ languages: [SpeechLanguage], chosen: String,
                                                   name: (String) -> String) -> [SpeechLanguage] {
        let offered = languages.sorted { name($0.id) < name($1.id) }
        guard !offered.contains(where: { $0.id == chosen }) else { return offered }
        return [SpeechLanguage(id: chosen, installed: false)] + offered
    }

    /// A Not downloaded row opens the model download screen with no note; so does a Failed row, whose Download
    /// starts the download again. Other rows do nothing.
    public func openModel(_ part: ModelPart) {
        guard models.first(where: { $0.part == part })?.status.opensModelDownload == true else { return }
        onEffect(.open(.modelDownload(noteID: nil)))
    }

    public func openVoices() { onEffect(.open(.savedVoices)) }
    public func openTrash() { onEffect(.open(.trash)) }
    public func openLicenses() { onEffect(.open(.licenses)) }
    public func turnOnNotifications() { onEffect(.openNotificationSettings) }
    public func openAppLanguage() { onEffect(.openAppLanguageSettings) }

    /// Notes in Recently Deleted count in neither total.
    public nonisolated static func totals(of notes: [Note]) -> LibraryTotals {
        let live = notes.filter { $0.trashedAt == nil }
        return LibraryTotals(notes: live.count, duration: live.reduce(0) { $0 + max($1.duration, 0) })
    }
}
