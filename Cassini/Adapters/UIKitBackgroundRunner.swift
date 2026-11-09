import UIKit
import BackgroundTasks
import CassiniEngine

/// Time to finish work after Cassini leaves the screen.
///
/// Work that reports progress (the transcription queue, a model download from Settings) runs as a
/// `BGContinuedProcessingTask`: iOS shows its title and progress, and its Stop button, like iOS taking the time back,
/// runs the work's expiration handler. The queue asks for it once per drain, from the screen, and gives each next job
/// its title with `update`. Each continued task held at a time has its own identifier, so the queue and a model
/// download can both hold one. When iOS refuses a request (it is only granted while Cassini is on the screen, and not
/// under heavy load), when both identifiers are held, and for other work such as saving the last edits, it falls back
/// to the finite time of `beginBackgroundTask`. Either way the work's
/// expiration handler runs on the main actor and the token ends before iOS's handler returns, exactly once: UIKit
/// terminates an app whose finite task is still running after its expiration handler, and documents no time after it.
/// What the work starts from its handler (the paused job's write) is best-effort; the queue's stored `system` hold lets
/// the launch repair finish it when Cassini is killed while suspended. Where the system has no continued processing
/// (`PlatformFacts.continuedProcessing`), every request takes the finite time and nothing touches `BGTaskScheduler`.
@MainActor final class UIKitBackgroundRunner: BackgroundRunner {
    /// Match `BGTaskSchedulerPermittedIdentifiers` (`io.codemyriad.cassini.transcription.*`). A request takes the first
    /// one that no held continued task has: the queue's drain, which asks first, usually gets the first.
    static let identifiers = ["io.codemyriad.cassini.transcription.queue", "io.codemyriad.cassini.transcription.work"]

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
        let identifier: String
        let progress: Progress
        let onExpire: Expiry
        let subtitle: String
        var title: String
        var task: BGContinuedProcessingTask?
        init(identifier: String, title: String, subtitle: String, progress: Progress, onExpire: @escaping Expiry) {
            self.identifier = identifier; self.title = title; self.subtitle = subtitle; self.progress = progress
            self.onExpire = onExpire
        }
    }

    private var held: [BackgroundToken: Held] = [:]
    private var registered: Set<String> = []
    private let platform: PlatformFacts

    init(platform: PlatformFacts) { self.platform = platform }

    func begin(title: String, subtitle: String, progress: Progress,
               onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        if platform.asksForContinuedProcessing(progressUnits: progress.totalUnitCount),
           let continued = submit(title: title, subtitle: subtitle, progress: progress, onExpire: onExpire) {
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

    /// Whether the token's work runs as continued processing rather than in the finite time.
    func holdsContinuedProcessing(_ token: BackgroundToken) -> Bool {
        if case .continued = held[token] { true } else { false }
    }

    func update(_ token: BackgroundToken, title: String) {
        guard case .continued(let continued) = held[token] else { return }
        continued.title = title
        continued.task?.updateTitle(title, subtitle: continued.subtitle)
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
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continued.identifier)
            }
        }
    }

    /// Asks iOS to run the work as continued processing, under an identifier no held continued task has; nil when it
    /// refuses or every identifier is held.
    private func submit(title: String, subtitle: String, progress: Progress, onExpire: @escaping Expiry) -> Continued? {
        let taken = Set(held.values.compactMap { entry -> String? in
            if case .continued(let continued) = entry { continued.identifier } else { nil }
        })
        guard let identifier = Self.identifiers.first(where: { !taken.contains($0) }), register(identifier) else {
            return nil
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { return nil }
        return Continued(identifier: identifier, title: title, subtitle: subtitle, progress: progress, onExpire: onExpire)
    }

    /// Registers the launch handler of `identifier` once; continued-processing handlers may be registered after launch.
    private func register(_ identifier: String) -> Bool {
        if registered.contains(identifier) { return true }
        let done = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.started(task) }
        }
        if done { registered.insert(identifier) }
        return done
    }

    /// iOS started the continued-processing task asked for last under the task's identifier.
    private func started(_ task: BGTask) {
        let pending = held.first { _, entry in
            if case .continued(let continued) = entry {
                continued.task == nil && continued.identifier == task.identifier
            } else { false }
        }
        guard let task = task as? BGContinuedProcessingTask, let (token, entry) = pending,
              case .continued(let continued) = entry else {
            // The work ended before iOS started its task.
            task.setTaskCompleted(success: true)
            return
        }
        continued.task = task
        task.updateTitle(continued.title, subtitle: continued.subtitle)
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
