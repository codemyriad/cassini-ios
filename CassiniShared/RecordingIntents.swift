import AppIntents
import Foundation

/// What the Live Activity's buttons ask of the recording.
enum RecordingIntentAction: Sendable {
    case pause, resume, finish
}

/// Where the Live Activity's buttons land. The intents run in the app's process; the app sets `handler` at launch.
/// In the widget extension it stays nil, and the buttons only describe themselves there. Each button names the
/// recording its activity belongs to, so an activity left by an earlier process cannot act on another recording.
@MainActor enum RecordingIntentRouter {
    static var handler: ((RecordingIntentAction, UUID) -> Void)?

    static func perform(_ action: RecordingIntentAction, noteID: String) {
        guard let id = UUID(uuidString: noteID) else { return }
        handler?(action, id)
    }
}

struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Pause recording", table: "Recording")
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("Recording", table: "Recording")) var noteID: String
    init() {}
    init(noteID: UUID) { self.noteID = noteID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        RecordingIntentRouter.perform(.pause, noteID: noteID)
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Resume recording", table: "Recording")
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("Recording", table: "Recording")) var noteID: String
    init() {}
    init(noteID: UUID) { self.noteID = noteID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        RecordingIntentRouter.perform(.resume, noteID: noteID)
        return .result()
    }
}

struct FinishRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Finish", table: "Recording")
    static let isDiscoverable = false
    @Parameter(title: LocalizedStringResource("Recording", table: "Recording")) var noteID: String
    init() {}
    init(noteID: UUID) { self.noteID = noteID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        RecordingIntentRouter.perform(.finish, noteID: noteID)
        return .result()
    }
}

/// The link a tap on the Live Activity opens: back to the Recording screen. The app reads it with
/// `DeepLinks.parse(url:)`; the widget extension does not link CassiniEngine, so a hosted test keeps the two together.
enum RecordingLink {
    static let url = URL(string: "cassini://recording")!
}
