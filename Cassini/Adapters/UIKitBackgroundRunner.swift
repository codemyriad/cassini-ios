import UIKit
import CassiniEngine

/// Finite background time from `beginBackgroundTask`. Expiration runs the work's handler and ends the task before
/// returning, as UIKit requires.
@MainActor final class UIKitBackgroundRunner: BackgroundRunner {
    private var tasks: [BackgroundToken: UIBackgroundTaskIdentifier] = [:]

    func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.end(token)
            }
        }
        if identifier != .invalid { tasks[token] = identifier }
        return token
    }

    func end(_ token: BackgroundToken) {
        guard let identifier = tasks.removeValue(forKey: token) else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
