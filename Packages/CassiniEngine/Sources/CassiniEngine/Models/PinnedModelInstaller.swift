import Foundation
import Synchronization
import CassiniNotebook

/// The only caller of `ModelInstaller` for the catalog's pinned models (Android's `ModelInstallOwner`, with the owner,
/// join, cancel and free-space rules `SpeakerModelInstaller` keeps for FluidAudio). Jobs and the standalone download
/// share it:
///
/// - At most one install runs at a time.
/// - A request for the same part set while one runs joins it: it waits on the same task and gets its progress and
///   outcome. A request for another part set waits for the running install to end, then starts its own, which finds
///   the files of the first one installed. So every artifact is fetched at most once.
/// - Progress goes into `ModelRepository.status` (downloading or verifying per part), into `status`, and to each
///   caller. A failure stays in the repository's status until the next install of that part.
/// - A caller that is cancelled stops waiting. When no caller waits any more, the install is cancelled. `cancel()`
///   cancels the shared install at once; every waiter then gets `CancellationError`. A cancelled install stops the
///   fetch, and `ArtifactFetcher` keeps its `.part` files for a Range resume. A request that arrives before a cancelled
///   fetch has ended waits for its end, so only one fetch is ever in flight.
/// - `stopDownloads()` is iOS ending the background time of a standalone download (`BGContinuedProcessingTask`
///   expiry, Android's foreground-service time-out): the parts show "Download stopped" until the next install.
///
/// The standalone download is no job: its only state is `status` and the `.part` files.
public final class PinnedModelInstaller: Sendable {
    /// What the installer does now (Android's `InstallState`).
    public enum Status: Hashable, Sendable {
        case idle
        /// An install of `parts` runs. `progress` is its latest report (nil before the first byte). `standalone` is
        /// true while the download from Settings or a banner waits on it; `waiters` counts every caller that waits.
        case installing(parts: Set<ModelPart>, progress: DownloadProgress?, standalone: Bool, waiters: Int)
    }

    private struct Install {
        let number: Int
        let parts: Set<ModelPart>
        var task: Task<InstallOutcome, any Error>?
        var waiting: [UUID: CheckedContinuation<InstallOutcome, any Error>] = [:]
        var listeners: [UUID: @Sendable (DownloadProgress) -> Void] = [:]
        var standalone: Set<UUID> = []
        var progress: DownloadProgress?
        /// Set by `stopDownloads`: when this install ends cancelled, it shows as "Download stopped".
        var stopped = false
        /// Cancelled, but its fetch has not ended: new requests wait for its end.
        var cancelling = false
        /// The requests that wait for this install to end before they start their own.
        var enders: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private struct Fields {
        var current: Install?
        var installs = 0
        /// The standalone downloads (`startDownload`) that have not ended.
        var downloads: [UUID: Task<Void, Never>] = [:]
        /// Callers that were cancelled before they could wait.
        var left: Set<UUID> = []
        var status: Status = .idle
        var lastOutcome: InstallOutcome?
    }

    /// A request that has to wait for the install `number` to end first.
    private struct Busy: Error { let number: Int }

    private let models: ModelRepository
    private let storage: any StorageProbe
    private let online: @Sendable () -> Bool
    private let executor: (any TaskExecutor)?
    private let onChange: @Sendable (Status) -> Void
    private let fields = Mutex(Fields())

    /// `online` tells whether the device has a network path now; `executor` runs the installs (tests pass a gated
    /// one); `onChange` receives every new `status`.
    public init(models: ModelRepository, storage: any StorageProbe, online: @escaping @Sendable () -> Bool,
                executor: (any TaskExecutor)? = nil, onChange: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.models = models; self.storage = storage; self.online = online; self.executor = executor
        self.onChange = onChange
    }

    public var status: Status { fields.withLock { $0.status } }

    /// The requests that wait for the running install to end before they start their own (tests wait on it).
    var waitingForEnd: Int { fields.withLock { $0.current?.enders.count ?? 0 } }

    /// How the last install ended: its outcome, or STOPPED_BY_SYSTEM when iOS stopped it (`stopDownloads`). Nil before
    /// the first one and after an install that was cancelled in another way.
    public var lastOutcome: InstallOutcome? { fields.withLock { $0.lastOutcome } }

    /// Installs the missing models of `parts`, or joins the install of the same parts that runs now. Cancelling the
    /// caller stops its wait; the install goes on while another caller waits. `granted` says the caller has its
    /// consent already (the speaker models, which have a consent of their own on iOS); otherwise the install asks
    /// `ModelRepository.consented()`.
    public func install(_ parts: Set<ModelPart>, granted: Bool = false,
                        onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> InstallOutcome {
        try await install(parts, onProgress, standalone: false, granted: granted)
    }

    /// The download from Settings or a banner, with no note: installs `parts` in the background and shows its
    /// progress through `status` and `ModelRepository.status`. `cancel()` stops it.
    @discardableResult public func startDownload(_ parts: Set<ModelPart> = Set(ModelPart.allCases)) -> Task<Void, Never> {
        let id = UUID()
        return fields.withLock { fields in
            let task = Task {
                // A cancelled download keeps its .part files; there is nothing more to do.
                _ = try? await self.install(parts, { _ in }, standalone: true, granted: false)
                self.fields.withLock { _ = $0.downloads.removeValue(forKey: id) }
            }
            fields.downloads[id] = task
            return task
        }
    }

    /// iOS ended the background time of a standalone download: every standalone wait ends, and the install ends when
    /// no job waits on it either. The `.part` files stay for a Range resume. When the install ends cancelled, each of
    /// its parts that is not installed shows "Download stopped" (STOPPED_BY_SYSTEM) until the next install, and
    /// `lastOutcome` tells it. False when no standalone download ran.
    @discardableResult public func stopDownloads() async -> Bool {
        let waiting = fields.withLock { fields in
            let tasks = Array(fields.downloads.values)
            if !tasks.isEmpty { fields.current?.stopped = true }
            return tasks
        }
        guard !waiting.isEmpty else { return false }
        for task in waiting { task.cancel() }
        for task in waiting { await task.value }
        return true
    }

    /// Cancels the install that runs now, if any: every caller stops waiting with `CancellationError`. Its `.part`
    /// files stay.
    public func cancel() {
        let (task, waiting) = fields.withLock { fields -> (Task<InstallOutcome, any Error>?, [CheckedContinuation<InstallOutcome, any Error>]) in
            guard var install = fields.current, !install.cancelling else { return (nil, []) }
            install.cancelling = true
            let waiting = Array(install.waiting.values)
            install.waiting = [:]
            install.listeners = [:]
            install.standalone = []
            fields.current = install
            return (install.task, waiting)
        }
        task?.cancel()
        for waiter in waiting { waiter.resume(throwing: CancellationError()) }
    }

    private func install(_ parts: Set<ModelPart>, _ onProgress: @escaping @Sendable (DownloadProgress) -> Void,
                         standalone: Bool, granted: Bool) async throws -> InstallOutcome {
        precondition(!parts.isEmpty, "No model part to install")
        while true {
            try Task.checkCancellation()
            let id = UUID()
            do {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstallOutcome, any Error>) in
                        attach(id, parts, onProgress, standalone, granted, continuation)
                    }
                } onCancel: {
                    self.leave(id)
                }
            } catch let busy as Busy {
                // Another part set installs, or a cancelled install has not ended: wait for its end, then try again.
                await waitForEnd(of: busy.number)
            }
        }
    }

    /// Joins or starts the install of `parts`, or resumes `continuation` with `Busy` when another part set runs or the
    /// current install is being cancelled (its fetch can block until the read timeout, and a new install must not fetch
    /// the same files at the same time).
    private func attach(_ id: UUID, _ parts: Set<ModelPart>, _ listener: @escaping @Sendable (DownloadProgress) -> Void,
                        _ standalone: Bool, _ granted: Bool,
                        _ continuation: CheckedContinuation<InstallOutcome, any Error>) {
        enum Attached { case joined(Status), started(Task<InstallOutcome, any Error>, Int, Status), busy(Int), left }
        let attached: Attached = fields.withLock { fields in
            if fields.left.remove(id) != nil { return .left }
            if let running = fields.current, running.cancelling || running.parts != parts { return .busy(running.number) }
            var started: (Task<InstallOutcome, any Error>, Int)?
            if fields.current == nil {
                fields.installs += 1
                let number = fields.installs
                let task = Task(executorPreference: executor) { try await self.run(number, parts, granted: granted) }
                fields.current = Install(number: number, parts: parts, task: task)
                started = (task, number)
            }
            fields.current?.waiting[id] = continuation
            fields.current?.listeners[id] = listener
            if standalone { fields.current?.standalone.insert(id) }
            let status = Self.publish(&fields)
            if let (task, number) = started { return .started(task, number, status) }
            return .joined(status)
        }
        switch attached {
        case .left: continuation.resume(throwing: CancellationError())
        case .busy(let number): continuation.resume(throwing: Busy(number: number))
        case .joined(let status): onChange(status)
        case .started(let task, let number, let status):
            onChange(status)
            Task {
                let result = await task.result
                self.finish(number, result)
            }
        }
    }

    /// A cancelled caller stops waiting at once; the install stops when nobody waits any more.
    private func leave(_ id: UUID) {
        let (waiter, task, status): (CheckedContinuation<InstallOutcome, any Error>?, Task<InstallOutcome, any Error>?, Status?) =
            fields.withLock { fields in
                guard var install = fields.current, let waiter = install.waiting.removeValue(forKey: id) else {
                    fields.left.insert(id)
                    return (nil, nil, nil)
                }
                install.listeners[id] = nil
                install.standalone.remove(id)
                var stop: Task<InstallOutcome, any Error>?
                if install.waiting.isEmpty && !install.cancelling {
                    install.cancelling = true
                    stop = install.task
                }
                fields.current = install
                return (waiter, stop, Self.publish(&fields))
            }
        task?.cancel()
        waiter?.resume(throwing: CancellationError())
        if let status { onChange(status) }
    }

    /// Waits until install `number` has ended; a cancelled caller stops waiting at once.
    private func waitForEnd(of number: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waits = fields.withLock { fields in
                    guard fields.current?.number == number, !Task.isCancelled else { return false }
                    fields.current?.enders[id] = continuation
                    return true
                }
                if !waits { continuation.resume() }
            }
        } onCancel: {
            let ender = self.fields.withLock { fields in
                fields.current?.number == number ? fields.current?.enders.removeValue(forKey: id) : nil
            }
            ender?.resume()
        }
    }

    /// The install task: Android's `ModelInstallOwner.run`.
    private func run(_ number: Int, _ parts: Set<ModelPart>, granted: Bool) async throws -> InstallOutcome {
        let ordered = ModelPart.allCases.filter(parts.contains)
        // A new install drops the failure an earlier one left in the status.
        for part in ordered { models.clearProgress(part) }
        do {
            try Task.checkCancellation()
            let store = RepositoryModelStore(models: models, storage: storage, online: online,
                                             consented: granted ? true : await models.consented())
            let outcome = try await ModelInstaller(store: store).install(parts) { progress in
                self.models.publishProgress(progress.part, Self.statusOf(progress))
                self.report(number, progress)
            }
            showOutcome(ordered, outcome)
            fields.withLock { $0.lastOutcome = outcome }
            await models.refresh()
            return outcome
        } catch {
            if ModelInstaller.isCancellation(error) {
                let (stopped, progress) = fields.withLock { fields in
                    fields.current?.number == number ? (fields.current?.stopped == true, fields.current?.progress) : (false, nil)
                }
                if stopped {
                    // iOS stopped it (stopDownloads): "Download stopped" until the next install. The refresh below
                    // shows the parts that were installed as ready again.
                    let error = DownloadError.stoppedBySystem
                    for part in ordered {
                        models.publishProgress(part, .failed(error.failure, detail: error.rawValue))
                    }
                    let part = progress?.part ?? ordered[0]
                    fields.withLock { $0.lastOutcome = .failed(part: part, error: error, requiredFreeBytes: 0) }
                } else {
                    for part in ordered { models.clearProgress(part) }
                    // A Cancel of the user is no failure: an older failure must not show again.
                    fields.withLock { $0.lastOutcome = nil }
                }
            }
            await models.refresh()
            throw error
        }
    }

    private func report(_ number: Int, _ progress: DownloadProgress) {
        let (listeners, status) = fields.withLock { fields -> ([@Sendable (DownloadProgress) -> Void], Status?) in
            guard fields.current?.number == number else { return ([], nil) }
            fields.current?.progress = progress
            return (fields.current.map { Array($0.listeners.values) } ?? [], Self.publish(&fields))
        }
        if let status { onChange(status) }
        for listener in listeners { listener(progress) }
    }

    /// Install `number` ended: the installer is idle, every caller gets the result, and the requests that waited for
    /// the end try again.
    private func finish(_ number: Int, _ result: Result<InstallOutcome, any Error>) {
        let install: Install? = fields.withLock { fields in
            guard let install = fields.current, install.number == number else { return nil }
            fields.current = nil
            fields.status = .idle
            return install
        }
        guard let install else { return }
        onChange(.idle)
        for waiter in install.waiting.values { waiter.resume(with: result) }
        for ender in install.enders.values { ender.resume() }
    }

    /// Clears the progress of every part, then shows the failures of `outcome` until the next install.
    private func showOutcome(_ parts: [ModelPart], _ outcome: InstallOutcome) {
        for part in parts { models.clearProgress(part) }
        let failures: [ModelPart: DownloadError] = switch outcome {
        case .failed(let part, let error, _): [part: error]
        case .installed(_, let failed): failed
        case .needsConsent: [:]
        }
        for (part, error) in failures { models.publishProgress(part, .failed(error.failure, detail: error.rawValue)) }
    }

    /// The status from the fields, stored in them.
    private static func publish(_ fields: inout Fields) -> Status {
        if let install = fields.current, !install.cancelling {
            fields.status = .installing(parts: install.parts, progress: install.progress,
                                        standalone: !install.standalone.isEmpty, waiters: install.waiting.count)
        }
        return fields.status
    }

    /// The repository status a download progress shows (Android's `ModelInstallOwner.statusOf`).
    public static func statusOf(_ progress: DownloadProgress) -> ModelStatus {
        if progress.verifying { return .verifying(percent: progress.percent) }
        let total = max(progress.totalBytes, 0)
        let bytes = min(max(progress.doneBytes, 0), total)
        return .downloading(percent: total == 0 ? 0 : Int(bytes * 100 / total), bytes: bytes, total: total)
    }
}
