import UIKit
import BackgroundTasks
import CassiniEngine

/// Time to finish work after Cassini leaves the screen.
///
/// Work that reports progress (a transcription job) runs as a `BGContinuedProcessingTask`: iOS shows its title and
/// progress, and its Stop button, like iOS taking the time back, runs the work's expiration handler. When iOS refuses
/// that request (it is only granted while Cassini is on the screen, and not under heavy load), and for other work
/// such as saving the last edits, it falls back to the finite time of `beginBackgroundTask`. Either way the
/// expiration handler runs synchronously on the main actor and the token ends right after it.
@MainActor final class UIKitBackgroundRunner: BackgroundRunner {
    /// Matches `BGTaskSchedulerPermittedIdentifiers` (`app.codemyriad.cassini.transcription.*`).
    static let identifierPrefix = "app.codemyriad.cassini.transcription"

    private enum Held {
        case finite(UIBackgroundTaskIdentifier, onExpire: @MainActor () -> Void)
        case continued(Continued)

        var onExpire: @MainActor () -> Void {
            switch self {
            case .finite(_, let onExpire): onExpire
            case .continued(let continued): continued.onExpire
            }
        }
    }

    /// A continued-processing request, and its task once iOS has started it.
    private final class Continued {
        let identifier: String
        let progress: Progress
        let onExpire: @MainActor () -> Void
        var task: BGContinuedProcessingTask?
        init(identifier: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) {
            self.identifier = identifier; self.progress = progress; self.onExpire = onExpire
        }
    }

    private var held: [BackgroundToken: Held] = [:]

    func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        if progress.totalUnitCount > 0, let continued = submit(token, title: title, progress: progress, onExpire: onExpire) {
            held[token] = .continued(continued)
            return token
        }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            MainActor.assumeIsolated { self?.expire(token) }
        }
        if identifier != .invalid { held[token] = .finite(identifier, onExpire: onExpire) }
        return token
    }

    func end(_ token: BackgroundToken) {
        switch held.removeValue(forKey: token) {
        case .finite(let identifier, _):
            UIApplication.shared.endBackgroundTask(identifier)
        case .continued(let continued):
            if let task = continued.task {
                task.setTaskCompleted(success: true)
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continued.identifier)
            }
        case nil:
            break
        }
    }

    /// Asks iOS to run the work as continued processing; nil when it refuses.
    private func submit(_ token: BackgroundToken, title: String, progress: Progress,
                        onExpire: @escaping @MainActor () -> Void) -> Continued? {
        let identifier = "\(Self.identifierPrefix).\(token.id.uuidString)"
        let continued = Continued(identifier: identifier, progress: progress, onExpire: onExpire)
        // Continued-processing handlers may be registered after launch; each identifier is registered once.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.started(task, token) }
        }
        guard registered else { return nil }
        let subtitle = String(localized: "Your audio stays on this device", table: "Transcription",
                              comment: "Subtitle of the system's progress while a note is transcribed")
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { return nil }
        return continued
    }

    /// iOS started the continued-processing task of `token`.
    private func started(_ task: BGTask, _ token: BackgroundToken) {
        guard let task = task as? BGContinuedProcessingTask, case .continued(let continued) = held[token] else {
            // The work ended before iOS started its task.
            task.setTaskCompleted(success: true)
            return
        }
        continued.task = task
        task.progress.totalUnitCount = 100
        task.progress.addChild(continued.progress, withPendingUnitCount: 100)
        task.expirationHandler = { [weak self] in
            // iOS calls this on a queue of its own; the work learns of it on the main actor right away.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.expire(token) } }
        }
    }

    private func expire(_ token: BackgroundToken) {
        guard let entry = held[token] else { return }
        entry.onExpire()
        switch held.removeValue(forKey: token) {
        case .finite(let identifier, _): UIApplication.shared.endBackgroundTask(identifier)
        case .continued(let continued): continued.task?.setTaskCompleted(success: false)
        case nil: break
        }
    }
}
