import Foundation
import CassiniEngine
import CassiniNotebook

/// The only owner of the speaker models' install, shared by analyses and the standalone download.
///
/// - One install runs at a time. A request while one runs joins it: it gets the same progress and outcome, and every
///   file is fetched once.
/// - A caller that is cancelled stops waiting at once; when nobody waits any more, the install is cancelled. A request
///   that arrives before that cancelled fetch has ended never joins it: it waits for its end, then starts its own
///   install, so only one fetch is ever in flight.
/// - An interrupted install keeps its complete files and FluidAudio's partial files, and the next install resumes
///   them. Only files with the wrong size or hash go first, or the whole folder when it holds another revision.
/// - Before the first byte the free space is checked (the files plus 32 MiB); short, the install fails with
///   `NOT_ENOUGH_STORAGE` and the bytes it asked for.
/// - After the fetch every file is checked against the manifest; a mismatch is `FILE_CHECK_FAILED` and the folder is
///   removed so the next install fetches it again.
/// - The status is stored: the last check or install, refreshed by `refresh()`; a failure stays until the next install.
///   A request while the stored status is ready checks only the marker and the sizes; `refresh()` hashes every file.
public actor SpeakerModelInstaller {
    /// Fetches the manifest's files into `directory/<folder>`, reporting the fraction done (nil while unknown).
    public typealias Fetch = @Sendable (_ directory: URL, _ progress: @escaping @Sendable (Double?) -> Void) async throws -> Void

    /// What the fetch reports, in order.
    private enum Report: Sendable {
        case fraction(Double?)
        case checking
    }

    /// The install that runs: its task, the callers waiting on it and their progress callbacks.
    private struct Install {
        let number: Int
        let task: Task<Void, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var listeners: [UUID: @Sendable (Double?) -> Void] = [:]
        /// Nobody waits any more and the task is cancelled, but its fetch has not ended: new requests wait for its end.
        var stopping = false
        /// The requests that wait for this stopping install to end.
        var successors: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    public nonisolated let manifest: SpeakerModelManifest
    /// The models directory; the files are in its `manifest.folder`.
    public nonisolated let directory: URL
    private let storage: any StorageProbe
    private let network: ModelNetworkGate
    private let fetch: Fetch
    private var stored: ModelPartStatus?
    private var current: Install?
    /// Fetches started, for the tests.
    public private(set) var fetches = 0

    public init(manifest: SpeakerModelManifest, directory: URL, storage: any StorageProbe,
                network: ModelNetworkGate, fetch: @escaping Fetch) {
        self.manifest = manifest
        self.directory = directory
        self.storage = storage
        self.network = network
        self.fetch = fetch
    }

    /// The stored status; the files are checked the first time.
    public func status() -> ModelPartStatus {
        if let stored { return stored }
        return refresh()
    }

    /// Checks the files again, unless an install runs; a failure is kept while the files are still not ready.
    @discardableResult public func refresh() -> ModelPartStatus {
        if current != nil, let stored { return stored }
        let status = Self.status(of: manifest.check(in: directory))
        if status == .ready || stored.map(Self.isFailure) != true { stored = status }
        return stored ?? status
    }

    /// How many callers wait on the install that runs; 0 when none runs.
    public var waiting: Int { current?.waiters.count ?? 0 }

    /// Installs the models, or joins the install that runs. Does nothing when they are ready.
    public func install(allowDownload: Bool, progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        while let current {
            guard current.stopping else { return try await wait(on: current.number, progress: progress) }
            await waitForEnd(of: current.number)
            try Task.checkCancellation()
        }
        if stored == .ready, manifest.looksReady(in: directory) { return }
        let check = manifest.check(in: directory)
        if check == .ready {
            stored = .ready
            return
        }
        guard allowDownload else { throw SpeakerAnalysisError.needsConsent }
        let required = manifest.requiredFreeBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard storage.availableBytes(at: directory) >= required else {
            stored = .failed(.notEnoughStorage)
            throw SpeakerAnalysisError.download(.notEnoughStorage, requiredFreeBytes: required)
        }
        let number = start(removingDamaged: check == .mismatch)
        try await wait(on: number, progress: progress)
    }

    private func start(removingDamaged damaged: Bool) -> Int {
        stored = .downloading(nil)
        fetches += 1
        let number = fetches
        let directory = directory, manifest = manifest, network = network, fetch = fetch
        // One stream keeps the reports in the order the fetch sent them.
        let (reports, reporter) = AsyncStream.makeStream(of: Report.self)
        let task = Task.detached {
            defer { reporter.finish() }
            try await Self.run(fetch, into: directory, manifest: manifest, network: network, removingDamaged: damaged,
                               progress: { reporter.yield(.fraction($0)) }, checking: { reporter.yield(.checking) })
        }
        current = Install(number: number, task: task)
        let delivery = Task {
            for await report in reports { self.apply(report, for: number) }
        }
        Task {
            let result = await task.result
            // Every report reaches the callers before the outcome does.
            await delivery.value
            self.finish(number, result)
        }
        return number
    }

    /// The fetch and the check of one install, off the actor; every failure is a `SpeakerAnalysisError` or a cancel.
    private static func run(_ fetch: Fetch, into directory: URL, manifest: SpeakerModelManifest, network: ModelNetworkGate,
                            removingDamaged damaged: Bool, progress: @escaping @Sendable (Double?) -> Void,
                            checking: @Sendable () -> Void) async throws {
        do {
            if damaged { manifest.removeDamaged(in: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await network.allowingDownloads { try await fetch(directory, progress) }
            try Task.checkCancellation()
            checking()
            guard manifest.check(in: directory) == .ready else {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(manifest.folder, isDirectory: true))
                throw SpeakerAnalysisError.download(.fileCheckFailed, requiredFreeBytes: 0)
            }
        } catch let error as SpeakerAnalysisError {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw SpeakerAnalysisError.download(downloadError(error), requiredFreeBytes: 0)
        }
    }

    private func wait(on number: Int, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard current?.number == number, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    stopIfNobodyWaits(number)
                    return
                }
                current?.waiters[id] = continuation
                current?.listeners[id] = progress
                // A caller that joins sees where the shared install stands.
                if case .downloading(let fraction) = stored { progress(fraction) }
            }
        } onCancel: {
            Task { await self.leave(number, id) }
        }
    }

    /// Waits until the stopping install `number` has ended; a cancelled caller stops waiting at once.
    private func waitForEnd(of number: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard current?.number == number, !Task.isCancelled else { return continuation.resume() }
                current?.successors[id] = continuation
            }
        } onCancel: {
            Task { await self.stopWaitingForEnd(of: number, id) }
        }
    }

    private func stopWaitingForEnd(of number: Int, _ id: UUID) {
        guard current?.number == number else { return }
        current?.successors.removeValue(forKey: id)?.resume()
    }

    /// A cancelled caller stops waiting at once; the install stops when nobody waits any more.
    private func leave(_ number: Int, _ id: UUID) {
        guard current?.number == number else { return }
        current?.listeners[id] = nil
        guard let continuation = current?.waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        stopIfNobodyWaits(number)
    }

    private func stopIfNobodyWaits(_ number: Int) {
        guard let install = current, install.number == number, install.waiters.isEmpty, !install.stopping else { return }
        current?.stopping = true
        install.task.cancel()
    }

    private func apply(_ report: Report, for number: Int) {
        guard let current, current.number == number else { return }
        switch report {
        case .checking:
            stored = .checking
        case .fraction(let fraction):
            if case .checking = stored { return }
            stored = .downloading(fraction.map { min(max($0, 0), 1) })
            for listener in current.listeners.values { listener(fraction) }
        }
    }

    private func finish(_ number: Int, _ result: Result<Void, Error>) {
        guard let install = current, install.number == number else { return }
        current = nil
        switch result {
        case .success:
            stored = .ready
        case .failure(SpeakerAnalysisError.download(let error, _)):
            stored = .failed(error)
        case .failure:
            stored = Self.status(of: manifest.check(in: directory))
        }
        for waiter in install.waiters.values { waiter.resume(with: result) }
        for successor in install.successors.values { successor.resume() }
    }

    private static func status(of check: SpeakerModelManifest.Check) -> ModelPartStatus {
        check == .ready ? .ready : .notDownloaded
    }

    private static func isFailure(_ status: ModelPartStatus) -> Bool {
        if case .failed = status { true } else { false }
    }
}

extension SpeakerModelInstaller {
    /// The download error a failed fetch stands for. Lost or refused connections are `NO_CONNECTION`; a transfer that
    /// broke off, a server error or a refused redirect is `INTERRUPTED`; a file that is not what the server promised is
    /// `FILE_CHECK_FAILED`; a full disk is `NOT_ENOUGH_STORAGE`; anything else is `INSTALL`.
    public static func downloadError(_ error: Error) -> DownloadError {
        if let error = error as? FluidDownloadError {
            switch error {
            case .downloadFailed(_, let underlying):
                let mapped = downloadError(underlying)
                return mapped == .install ? .interrupted : mapped
            case .invalidArtifact: return .fileCheckFailed
            case .invalidResponse, .rateLimited, .modelNotFound, .htmlErrorResponse, .stalled: return .interrupted
            case .networkDisabled: return .noConnection
            case .modelMissing: return .install
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed, .callIsActive:
                return .noConnection
            case .cannotCreateFile, .cannotWriteToFile:
                return .install
            default:
                return .interrupted
            }
        }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return .notEnoughStorage }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return .notEnoughStorage }
        if error.domain == "HTTP" { return .interrupted }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return downloadError(underlying) }
        return .install
    }
}
