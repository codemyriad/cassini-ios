import AppIntents
import Foundation

/// What the Live Activity's buttons ask of the recording.
enum RecordingIntentAction: Sendable {
    case pause, resume, finish
}

/// Where the Live Activity's buttons land. The intents run in the app's process; the app sets `handler` at launch.
/// In the widget extension it stays nil, and the buttons only describe themselves there.
@MainActor enum RecordingIntentRouter {
    static var handler: ((RecordingIntentAction) -> Void)?

    static func perform(_ action: RecordingIntentAction) { handler?(action) }
}

struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Pause recording", table: "Recording")
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        RecordingIntentRouter.perform(.pause)
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Resume recording", table: "Recording")
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        RecordingIntentRouter.perform(.resume)
        return .result()
    }
}

struct FinishRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Finish", table: "Recording")
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        RecordingIntentRouter.perform(.finish)
        return .result()
    }
}

/// The link a tap on the Live Activity opens: back to the Recording screen.
enum RecordingLink {
    static let url = URL(string: "cassini://recording")!

    static func matches(_ url: URL) -> Bool { url.scheme == Self.url.scheme && url.host() == Self.url.host() }
}
