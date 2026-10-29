import Foundation
@preconcurrency import UserNotifications
import CassiniEngine
import CassiniNotebook

/// The part of `UNUserNotificationCenter` the notifier uses, so hosted tests can watch what it posts.
protocol UserNotificationCenter: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: UserNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus { await notificationSettings().authorizationStatus }
}

/// The results notifications (Android `ProcessingNotifications` and `RecordingNotifications`), posted by the
/// coordinators only while Cassini is not on the screen. Each note has at most one: its id is the request's, so a newer
/// result replaces the older one. They are silent and grouped in one thread; with previews hidden the Lock Screen shows
/// the category's placeholder, which never names the note. Permission is asked once.
struct UNNotifier: Notifier {
    static let thread = "io.codemyriad.cassini.results"

    let center: any UserNotificationCenter

    init(center: any UserNotificationCenter = UNUserNotificationCenter.current()) { self.center = center }

    func authorizationStatus() async -> NotificationAuth {
        switch await center.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestOnce() async {
        guard await center.authorizationStatus() == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge])
    }

    func post(_ notification: ResultNotification) async {
        try? await center.add(Self.request(notification))
    }

    func remove(noteID: UUID) async {
        center.removeDeliveredNotifications(withIdentifiers: [noteID.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [noteID.uuidString])
    }

    /// The request for `notification`: shown at once, identified by its note.
    static func request(_ notification: ResultNotification) -> UNNotificationRequest {
        let text = NotificationCopy.text(notification)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = NotificationCategory(notification.kind).rawValue
        content.threadIdentifier = thread
        content.userInfo = DeepLinks.userInfo(noteID: notification.noteID)
        content.sound = nil
        content.interruptionLevel = .active
        return UNNotificationRequest(identifier: notification.noteID.uuidString, content: content, trigger: nil)
    }
}

/// One category per kind of result: its hidden-preview placeholder, and Resume for a stopped transcription.
enum NotificationCategory: String, CaseIterable {
    case transcribed = "result.transcribed"
    case failed = "result.failed"
    case ready = "result.ready"
    case paused = "result.paused"
    case stopped = "result.stopped"
    case recordingStopped = "result.recordingStopped"
    case microphoneFailed = "result.microphoneFailed"

    init(_ kind: ResultNotification.Kind) {
        switch kind {
        case .transcribed: self = .transcribed
        case .failed: self = .failed
        case .readyToTranscribe: self = .ready
        case .pausedBySystem: self = .paused
        case .transcriptionStopped: self = .stopped
        case .recordingStopped: self = .recordingStopped
        case .microphoneFailed: self = .microphoneFailed
        }
    }

    var offersResume: Bool { self == .paused || self == .stopped }

    var category: UNNotificationCategory {
        let actions = offersResume
            ? [UNNotificationAction(identifier: DeepLinks.resumeAction, title: NotificationCopy.resume, options: [.foreground])]
            : []
        return UNNotificationCategory(identifier: rawValue, actions: actions, intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: NotificationCopy.placeholder(self), options: [])
    }

    /// Registers every category; called at launch, before any notification can be shown or tapped.
    static func register(in center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(Set(allCases.map(\.category)))
    }
}

/// Hears the taps on Cassini's notifications and hands them on as deep links, keeping a tap that came before the app
/// was ready (a cold start) until a handler is set.
@MainActor final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    private var pending: [DeepLink] = []

    var handler: ((DeepLink) -> Void)? {
        didSet {
            guard let handler else { return }
            let links = pending
            pending = []
            links.forEach(handler)
        }
    }

    func receive(_ link: DeepLink) {
        if let handler { handler(link) } else { pending.append(link) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard let link = DeepLinks.parse(userInfo: info, action: action) else { return }
        await MainActor.run { receive(link) }
    }

    /// Results are posted only while Cassini is hidden; one that arrives as it comes back is not shown on top of it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [] }
}
