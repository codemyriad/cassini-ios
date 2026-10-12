import Foundation
import CassiniEngine

/// The live notifier until WP9's `UNNotifier` replaces it: it never asks for permission and posts nothing, as when
/// notifications are off. The notifications themselves, their copy and their permission prompt are WP9's.
struct SilentNotifier: Notifier {
    func authorizationStatus() async -> NotificationAuth { .denied }
    func requestOnce() async {}
    func post(_ notification: ResultNotification) async {}
    func remove(noteID: UUID) async {}
}
