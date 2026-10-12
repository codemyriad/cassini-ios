import UIKit
import BackgroundTasks
import CassiniEngine

/// Time to finish work after Cassini leaves the screen.
///
/// Work that reports progress (the transcription queue) runs as one `BGContinuedProcessingTask`: iOS shows its title
/// and progress, and its Stop button, like iOS taking the time back, runs the work's expiration handler. The queue
/// asks for it once per drain, from the screen, and gives each next job its title with `update`. When iOS refuses
/// that request (it is only granted while Cassini is on the screen, and not under heavy load), and for other work
/// such as saving the last edits, it falls back to the finite time of `beginBackgroundTask`. Either way the work's
/// expiration handler runs on the main actor and the token ends before iOS's handler returns, exactly once: UIKit
/// terminates an app whose finite task is still running after its expiration handler, and documents no time after it.
/// What the work starts from its handler (the paused job's write) is best-effort; the queue's stored `system` hold lets
/// the launch repair finish it when Cassini is killed while suspended.
@MainActor final class UIKitBackgroundRunner: BackgroundRunner {
    /// Matches `BGTaskSchedulerPermittedIdentifiers` (`app.codemyriad.cassini.transcription.*`). One identifier
    /// serves every drain: at most one continued task is held at a time.
    static let identifier = "app.codemyriad.cassini.transcription.queue"

    private typealias Expiry = @MainActor () -> Void

    private enum Held {
        case finite(UIBackgroundTaskIdentifier, onExpire: Expiry)
        case continued(Continued)

        var onExpire: Expiry {
            switch self {
            case .finite(_, let onExpire): onExpire
            case .continued(let continued): continued.onExpire
            }
        }
    }

    /// A continued-processing request, and its task once iOS has started it.
    private final class Continued {
        let progress: Progress
        let onExpire: Expiry
        var title: String
        var task: BGContinuedProcessingTask?
        init(title: String, progress: Progress, onExpire: @escaping Expiry) {
            self.title = title; self.progress = progress; self.onExpire = onExpire
        }
    }

    private var held: [BackgroundToken: Held] = [:]
    private var registered = false

    private static var subtitle: String {
        String(localized: "Your audio stays on this device", table: "Transcription",
               comment: "Subtitle of the system's progress while a note is transcribed")
    }

    func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        if progress.totalUnitCount > 0, let continued = submit(title: title, progress: progress, onExpire: onExpire) {
            held[token] = .continued(continued)
            return token
        }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            // UIKit calls this on the main thread.
            MainActor.assumeIsolated { self?.expire(token) }
        }
        if identifier != .invalid { held[token] = .finite(identifier, onExpire: onExpire) }
        return token
    }

    func update(_ token: BackgroundToken, title: String) {
        guard case .continued(let continued) = held[token] else { return }
        continued.title = title
        continued.task?.updateTitle(title, subtitle: Self.subtitle)
    }

    func end(_ token: BackgroundToken) {
        guard let entry = held.removeValue(forKey: token) else { return }
        release(entry, success: true)
    }

    private func release(_ entry: Held, success: Bool) {
        switch entry {
        case .finite(let identifier, _):
            UIApplication.shared.endBackgroundTask(identifier)
        case .continued(let continued):
            if let task = continued.task {
                task.setTaskCompleted(success: success)
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            }
        }
    }

    /// Asks iOS to run the work as continued processing; nil when it refuses or a continued task is held already.
    private func submit(title: String, progress: Progress, onExpire: @escaping Expiry) -> Continued? {
        let isContinued: (Held) -> Bool = { if case .continued = $0 { true } else { false } }
        guard !held.values.contains(where: isContinued), register() else {
            return nil
        }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: title, subtitle: Self.subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { return nil }
        return Continued(title: title, progress: progress, onExpire: onExpire)
    }

    /// Registers the launch handler once; continued-processing handlers may be registered after launch.
    private func register() -> Bool {
        if registered { return true }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.started(task) }
        }
        return registered
    }

    /// iOS started the continued-processing task asked for last.
    private func started(_ task: BGTask) {
        let pending = held.first { _, entry in
            if case .continued(let continued) = entry { continued.task == nil } else { false }
        }
        guard let task = task as? BGContinuedProcessingTask, let (token, entry) = pending,
              case .continued(let continued) = entry else {
            // The work ended before iOS started its task.
            task.setTaskCompleted(success: true)
            return
        }
        continued.task = task
        task.updateTitle(continued.title, subtitle: Self.subtitle)
        task.progress.totalUnitCount = 100
        task.progress.addChild(continued.progress, withPendingUnitCount: 100)
        task.expirationHandler = { [weak self] in
            // The work must learn of it before this returns, so it does not start another step meanwhile.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.expire(token) }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { self?.expire(token) } }
            }
        }
    }

    /// iOS takes the token's time back: its work learns of it, then the token ends, both before iOS's handler returns.
    private func expire(_ token: BackgroundToken) {
        guard let entry = held.removeValue(forKey: token) else { return }
        entry.onExpire()
        release(entry, success: false)
    }
}
