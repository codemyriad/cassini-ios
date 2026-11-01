import Foundation

/// The parts of the banner catalogue (Android `BannerGroup`).
public enum BannerGroup: String, CaseIterable, Hashable, Sendable {
    case trust, recording, transcription, download, library
}

/// A banner button.
public enum BannerAction: String, CaseIterable, Hashable, Sendable {
    case resume, startOver, tryAgain, transcribe, transcribeAgain, playAnyway, open, openNote, openSettings, turnOn
    case download, downloadAgain, retry, cancel, chooseAnother, record, `import`, `continue`
}

/// The `BannerArgs` fields a kind's copy reads.
public enum BannerArg: String, CaseIterable, Hashable, Sendable {
    case count, text, ms1, ms2, bytes, bytes2, percent, part, bySystem
}

/// The banner catalogue (Android `BannerKind`): every kind with its tone, group, the arguments its copy reads, its
/// actions (the first filled, the second outlined), whether the app emits it and whether the user can close it. The
/// copy is the app's (`BannerCopy`, table Notices). The raw value is Android's kind name and a banner's default id.
///
/// Not on iOS: `NO_ENCODER` (Cassini always has its Opus encoder), `TX_MEMORY` (iOS ends an app out of memory without
/// a catchable error), `IMPORT_WAV` (AVFoundation reads every WAV) and `REC_STOPPED_FILE_LIMIT` (the capture is a CAF
/// file without M4A's 1 GiB end). iOS only:
/// `REC_INPUT_LOST`, `REC_COMPRESSION_FAILED`, `NOTES_UNREADABLE` and `DL_PIN_UNAVAILABLE`.
public enum BannerKind: String, CaseIterable, Hashable, Sendable {
    // Document trust.
    case trustVerified = "TRUST_VERIFIED"
    case trustNotVerified = "TRUST_NOT_VERIFIED"
    case trustAudioChanged = "TRUST_AUDIO_CHANGED"
    case trustUnreadable = "TRUST_UNREADABLE"
    case trustNewerFormat = "TRUST_NEWER_FORMAT"
    case plainAudio = "PLAIN_AUDIO"
    case unplayable = "UNPLAYABLE"

    // Recording.
    case recPausedOtherApp = "REC_PAUSED_OTHER_APP"
    /// The input in use went away (headphones unplugged). iOS only.
    case recInputLost = "REC_INPUT_LOST"
    case recStorageLow = "REC_STORAGE_LOW"
    case recStoppedStorage = "REC_STOPPED_STORAGE"
    case recMicOff = "REC_MIC_OFF"
    case recMicFailed = "REC_MIC_FAILED"
    case recCouldNotStart = "REC_COULD_NOT_START"
    case recovered = "RECOVERED"
    /// A finished recording stays in its original quality: compression could not finish. iOS only.
    case recCompressionFailed = "REC_COMPRESSION_FAILED"

    // Transcription.
    case txPaused = "TX_PAUSED"
    case txPausedEarly = "TX_PAUSED_EARLY"
    case txQueueHeld = "TX_QUEUE_HELD"
    case txCalculating = "TX_CALCULATING"
    case txBattery = "TX_BATTERY"
    case txOneVoice = "TX_ONE_VOICE"
    case txCheckpointMismatch = "TX_CHECKPOINT_MISMATCH"
    /// `BannerArgs.text` is the failure's message; without it the body is only "Your recording is kept."
    case txFailed = "TX_FAILED"

    // Model download.
    /// The title names `BannerArgs.part` (speech recognition when nil); the percent comes from the bytes when
    /// `BannerArgs.percent` is nil.
    case dlDownloading = "DL_DOWNLOADING"
    case dlChecking = "DL_CHECKING"
    case dlNoConnection = "DL_NO_CONNECTION"
    case dlStopped = "DL_STOPPED"
    case dlNoSpace = "DL_NO_SPACE"
    case dlFileCheck = "DL_FILE_CHECK"
    case dlInstallFailed = "DL_INSTALL_FAILED"
    /// The model host does not offer the model as this build pins it: only an update of Cassini helps, so there is no
    /// Retry. iOS only.
    case dlPinUnavailable = "DL_PIN_UNAVAILABLE"
    case dlRecordNow = "DL_RECORD_NOW"

    // Library and import.
    case libEmpty = "LIB_EMPTY"
    case libNoMatch = "LIB_NO_MATCH"
    case importing = "IMPORTING"
    case importTooLarge = "IMPORT_TOO_LARGE"
    case importNoSpace = "IMPORT_NO_SPACE"
    case importOpen = "IMPORT_OPEN"
    case notificationsOff = "NOTIFICATIONS_OFF"
    case voicesUnreadable = "VOICES_UNREADABLE"
    /// The library could not be opened: not the same as an empty one.
    case libUnavailable = "LIB_UNAVAILABLE"
    /// Some notes' metadata could not be read; their files are kept. iOS only.
    case notesUnreadable = "NOTES_UNREADABLE"

    public var tone: Tone { entry.tone }
    public var group: BannerGroup { entry.group }
    /// The arguments the copy reads.
    public var uses: Set<BannerArg> { entry.uses }
    /// The catalogue actions, the default of `BannerSpec.actions`; never more than two.
    public var actions: [BannerAction] { entry.actions }
    /// False for the catalogue-only kinds the app never shows.
    public var appEmitted: Bool { entry.appEmitted }
    /// The user can close it.
    public var dismissible: Bool { entry.dismissible }
    /// A kind Android does not have.
    public var iOSOnly: Bool { [.recInputLost, .recCompressionFailed, .notesUnreadable, .dlPinUnavailable].contains(self) }

    private struct Entry {
        var tone: Tone
        var group: BannerGroup
        var uses: Set<BannerArg> = []
        var actions: [BannerAction] = []
        var appEmitted = true
        var dismissible = false
    }

    // One row of the catalogue table per kind.
    private var entry: Entry {
        switch self {
        case .trustVerified: Entry(tone: .ok, group: .trust)
        case .trustNotVerified: Entry(tone: .warn, group: .trust, actions: [.playAnyway])
        case .trustAudioChanged: Entry(tone: .warn, group: .trust, actions: [.transcribeAgain])
        case .trustUnreadable: Entry(tone: .error, group: .trust, actions: [.transcribeAgain])
        case .trustNewerFormat: Entry(tone: .error, group: .trust)
        case .plainAudio: Entry(tone: .plain, group: .trust, uses: [.text], actions: [.transcribe])
        case .unplayable: Entry(tone: .error, group: .trust, uses: [.text])

        case .recPausedOtherApp: Entry(tone: .warn, group: .recording, actions: [.resume])
        case .recInputLost: Entry(tone: .warn, group: .recording, actions: [.resume])
        case .recStorageLow: Entry(tone: .warn, group: .recording, uses: [.ms1])
        case .recStoppedStorage: Entry(tone: .warn, group: .recording, uses: [.bytes], actions: [.openNote])
        case .recMicOff: Entry(tone: .error, group: .recording, actions: [.openSettings])
        case .recMicFailed: Entry(tone: .error, group: .recording, actions: [.openNote])
        case .recCouldNotStart: Entry(tone: .error, group: .recording, actions: [.tryAgain])
        case .recovered: Entry(tone: .info, group: .recording, uses: [.count, .ms1], actions: [.open], dismissible: true)
        case .recCompressionFailed: Entry(tone: .info, group: .recording, dismissible: true)

        case .txPaused:
            Entry(tone: .warn, group: .transcription, uses: [.ms1, .ms2, .bySystem], actions: [.resume, .startOver])
        case .txPausedEarly: Entry(tone: .warn, group: .transcription, uses: [.bySystem], actions: [.resume])
        case .txQueueHeld: Entry(tone: .warn, group: .transcription, uses: [.count], actions: [.continue])
        case .txCalculating: Entry(tone: .info, group: .transcription, appEmitted: false)
        case .txBattery: Entry(tone: .info, group: .transcription, appEmitted: false)
        case .txOneVoice: Entry(tone: .warn, group: .transcription, actions: [.transcribeAgain])
        case .txCheckpointMismatch: Entry(tone: .error, group: .transcription, actions: [.startOver])
        case .txFailed: Entry(tone: .error, group: .transcription, uses: [.text], actions: [.tryAgain])

        case .dlDownloading: Entry(tone: .info, group: .download, uses: [.part, .percent, .bytes, .bytes2], actions: [.cancel])
        case .dlChecking: Entry(tone: .info, group: .download, uses: [.percent])
        case .dlNoConnection: Entry(tone: .error, group: .download, actions: [.retry])
        case .dlStopped: Entry(tone: .error, group: .download, uses: [.bySystem], actions: [.retry])
        case .dlNoSpace: Entry(tone: .error, group: .download, uses: [.bytes], actions: [.retry])
        case .dlFileCheck: Entry(tone: .error, group: .download, actions: [.downloadAgain])
        case .dlInstallFailed: Entry(tone: .error, group: .download, actions: [.tryAgain])
        case .dlPinUnavailable: Entry(tone: .error, group: .download, dismissible: true)
        case .dlRecordNow: Entry(tone: .info, group: .download, actions: [.download])

        case .libEmpty: Entry(tone: .plain, group: .library, actions: [.record, .import])
        case .libNoMatch: Entry(tone: .plain, group: .library, uses: [.text])
        case .importing: Entry(tone: .info, group: .library, uses: [.text])
        case .importTooLarge: Entry(tone: .error, group: .library, actions: [.chooseAnother])
        case .importNoSpace: Entry(tone: .error, group: .library, uses: [.bytes], actions: [.tryAgain])
        case .importOpen: Entry(tone: .error, group: .library, actions: [.chooseAnother])
        case .notificationsOff: Entry(tone: .info, group: .library, actions: [.turnOn])
        case .voicesUnreadable: Entry(tone: .error, group: .library)
        case .libUnavailable: Entry(tone: .error, group: .library)
        case .notesUnreadable: Entry(tone: .error, group: .library, uses: [.count], dismissible: true)
        }
    }
}
