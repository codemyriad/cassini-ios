import Foundation
import Synchronization
import CassiniEngine

public final class FakeNotifier: Notifier {
    private struct State { var auth: NotificationAuth; var requests = 0; var posted: [ResultNotification] = [] }
    private let state: Mutex<State>

    public init(auth: NotificationAuth = .authorized) { state = Mutex(State(auth: auth)) }

    public var posted: [ResultNotification] { state.withLock { $0.posted } }
    public var requestCount: Int { state.withLock { $0.requests } }

    public func authorizationStatus() async -> NotificationAuth { state.withLock { $0.auth } }
    public func requestOnce() async { state.withLock { $0.requests += 1 } }
    public func post(_ notification: ResultNotification) async {
        state.withLock { state in
            state.posted.removeAll { $0.noteID == notification.noteID }
            state.posted.append(notification)
        }
    }
    public func remove(noteID: UUID) async { state.withLock { $0.posted.removeAll { $0.noteID == noteID } } }
}
