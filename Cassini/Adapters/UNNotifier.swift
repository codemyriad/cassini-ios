import Foundation
import UserNotifications
import CassiniEngine
import CassiniNotebook

/// Result notifications through `UNUserNotificationCenter`, one per note: a newer one replaces the note's last.
struct UNNotifier: Notifier {
    func authorizationStatus() async -> NotificationAuth {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestOnce() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func post(_ notification: ResultNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.headline
        content.body = notification.body
        content.threadIdentifier = notification.noteID.uuidString
        content.userInfo = ["noteID": notification.noteID.uuidString]
        let request = UNNotificationRequest(identifier: notification.noteID.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func remove(noteID: UUID) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [noteID.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [noteID.uuidString])
    }
}

extension ResultNotification {
    var headline: String {
        switch kind {
        case .transcribed: String(localized: "Transcribed: \(title)", table: "Transcription")
        case .failed: String(localized: "Couldn’t transcribe \(title)", table: "Transcription")
        case .readyToTranscribe: String(localized: "Ready to transcribe", table: "Transcription")
        case .pausedBySystem: String(localized: "Transcription paused by iOS", table: "Transcription")
        case .transcriptionStopped: String(localized: "Transcription stopped", table: "Transcription")
        case .recordingStopped: String(localized: "Recording stopped", table: "Transcription")
        case .microphoneFailed: String(localized: "Microphone stopped working", table: "Transcription")
        }
    }

    var body: String {
        switch kind {
        case .transcribed(let speakers, let duration):
            String(localized: "\(speakers) speakers · \(TimeText.clock(duration))", table: "Transcription")
        case .failed(let failure):
            failure.transcriptionMessage
        case .readyToTranscribe:
            String(localized: "\(title) is waiting. Open Cassini to start.", table: "Transcription")
        case .pausedBySystem:
            String(localized: "iOS needed the time back. Open Cassini to resume.", table: "Transcription")
        case .transcriptionStopped:
            String(localized: "Cassini closed while transcribing \(title).", table: "Transcription")
        case .recordingStopped:
            String(localized: "Less than 200 MB free. The recording so far is saved.", table: "Transcription")
        case .microphoneFailed:
            String(localized: "Recording ended. The audio so far is in your library.", table: "Transcription")
        }
    }
}
