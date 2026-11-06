import Foundation
import Testing
import UserNotifications
import CassiniEngine
import CassiniNotebook
@testable import Cassini

/// A notification center that keeps what it is given, as the system keeps one notification per identifier. Requests
/// are not `Sendable`, so a lock guards them.
private final class RecordingCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var status: UNAuthorizationStatus
    private var requestCount = 0
    private var requestsDelivered: [UNNotificationRequest] = []

    init(status: UNAuthorizationStatus) { self.status = status }

    var delivered: [UNNotificationRequest] { lock.withLock { requestsDelivered } }
    var requests: Int { lock.withLock { requestCount } }

    func authorizationStatus() async -> UNAuthorizationStatus { lock.withLock { status } }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { requestCount += 1; status = .authorized }
        return true
    }
    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock {
            requestsDelivered.removeAll { $0.identifier == request.identifier }
            requestsDelivered.append(request)
        }
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        lock.withLock { requestsDelivered.removeAll { identifiers.contains($0.identifier) } }
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}

/// The copy and the shape of the results notifications.
@Suite struct NotificationTests {
    let note = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!

    // ports: ProcessingNotificationsTest#resultsAreReplacedPerNoteAndHideTheTitleInPublic
    @Test func resultsAreReplacedPerNoteAndHideTheTitleInPublic() async throws {
        let center = RecordingCenter(status: .authorized)
        let notifier = UNNotifier(center: center)
        await notifier.post(ResultNotification(noteID: note, title: "Meeting", kind: .readyToTranscribe))
        await notifier.post(ResultNotification(noteID: note, title: "Meeting", kind: .failed(.checkpointMismatch)))
        let failed = try #require(center.delivered.first)
        #expect(center.delivered.count == 1, "one notification per note: the newer replaces the older")
        #expect(failed.identifier == note.uuidString)
        #expect(failed.content.title == "Couldn’t transcribe Meeting")
        #expect(failed.content.body == "Saved progress no longer matches. Your recording is kept.")
        #expect(failed.content.threadIdentifier == UNNotifier.thread)
        #expect(failed.content.sound == nil)
        #expect(DeepLinks.parse(userInfo: failed.content.userInfo) == .note(note))

        // With previews hidden the Lock Screen shows the category's placeholder, never the title.
        let category = try #require(NotificationCategory(rawValue: failed.content.categoryIdentifier)?.category)
        #expect(category.hiddenPreviewsBodyPlaceholder == "A note couldn’t be transcribed")
        #expect(!category.options.contains(.hiddenPreviewsShowTitle))
        for kind in NotificationCategory.allCases {
            #expect(!kind.category.hiddenPreviewsBodyPlaceholder.contains("Meeting"))
        }

        await notifier.remove(noteID: note)
        #expect(center.delivered.isEmpty)
    }

    // ports: ProcessingNotificationsTest#pausedByAndroidWithoutWordsDoesNotShowZeroTimes
    @Test func pausedByIOSShowsNoTimesAndOffersResume() throws {
        let paused = UNNotifier.request(ResultNotification(noteID: note, title: "Meeting", kind: .pausedBySystem))
        #expect(paused.content.title == "Transcription paused by iOS")
        #expect(paused.content.body == "iOS needed the time back. Open Cassini to resume.")
        #expect(!paused.content.body.contains("00:00"))
        let category = try #require(NotificationCategory(rawValue: paused.content.categoryIdentifier))
        #expect(category.category.actions.map(\.identifier) == [DeepLinks.resumeAction])
        #expect(category.category.actions.first?.title == "Resume")
        #expect(category.category.actions.first?.options.contains(.foreground) == true)
        #expect(category.category.hiddenPreviewsBodyPlaceholder == "Open Cassini to resume.")
    }

    @Test func everyKindHasItsCopy() {
        let text = { (kind: ResultNotification.Kind) in
            NotificationCopy.text(ResultNotification(noteID: note, title: "Meeting", kind: kind))
        }
        #expect(text(.transcribed(speakers: 3, duration: 48 * 60 + 13))
                == .init(title: "Transcribed: Meeting", body: "3 speakers · 48:13"))
        #expect(text(.transcribed(speakers: 1, duration: 3723)).body == "1 speaker · 1:02:03")
        #expect(text(.readyToTranscribe) == .init(title: "Ready to transcribe", body: "Meeting is waiting. Open Cassini to start."))
        #expect(text(.transcriptionStopped)
                == .init(title: "Transcription stopped", body: "Cassini closed while transcribing Meeting."))
        #expect(text(.recordingStopped)
                == .init(title: "Recording stopped", body: "Less than 200 MB free. The recording so far is saved."))
        #expect(text(.microphoneFailed)
                == .init(title: "Microphone stopped working", body: "Recording ended. The audio so far is in your library."))
        #expect(text(.failed(.download(.noConnection))).body == "No connection. Connect to the internet and try again.")
        #expect(text(.failed(.documentRefused(.unverified))).body
                == "This transcript can’t take a new version. Your recording is kept.")
        #expect(text(.failed(.empty)).body == JobFailure.empty.transcriptionMessage)
        // ports: ProcessingNotificationsTest (failureText): each download error has its own failure's text.
        #expect(text(.failed(.download(.notEnoughStorage))).body
                == "Your device is running low on storage. Free up space, then try again.")
        #expect(text(.failed(.download(.fileCheckFailed))).body == "Model verification failed. Please download it again.")
        #expect(text(.failed(.download(.install))).body == "Could not save the model. Free some space and retry.")
        #expect(text(.failed(.download(.interrupted))).body == "Model download failed. Check your connection and retry.")
        // iOS only: a model the host no longer offers as pinned says that only an update helps.
        #expect(text(.failed(.download(.pinUnavailable))).body
                == "This version of the model is no longer offered for download. Update Cassini, then try again.")
        #expect(text(.failed(.unknown)).body == "Something went wrong. Please try again.")
        #expect(NotificationCategory(.transcriptionStopped).offersResume)
        #expect(!NotificationCategory(.transcribed(speakers: 1, duration: 1)).offersResume)
    }

    @Test func permissionIsAskedOnlyWhileUndetermined() async {
        let undetermined = RecordingCenter(status: .notDetermined)
        let notifier = UNNotifier(center: undetermined)
        #expect(await notifier.authorizationStatus() == .notDetermined)
        await notifier.requestOnce()
        await notifier.requestOnce()
        #expect(undetermined.requests == 1)
        #expect(await notifier.authorizationStatus() == .authorized)

        let denied = RecordingCenter(status: .denied)
        await UNNotifier(center: denied).requestOnce()
        #expect(denied.requests == 0)
        #expect(await UNNotifier(center: denied).authorizationStatus() == .denied)
    }
}
