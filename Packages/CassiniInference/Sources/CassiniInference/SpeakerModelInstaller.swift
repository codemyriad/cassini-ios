import Foundation
import CassiniEngine
import CassiniNotebook

/// The only owner of the speaker models' install, shared by analyses and the standalone download.
///
/// - One install runs at a time. A request while one runs joins it: it gets the same progress and outcome, and every
///   file is fetched once.
/// - A caller that is cancelled stops waiting at once; when nobody waits any more, the install is cancelled. The
///   partial files FluidAudio keeps let the next install resume.
/// - Before the first byte the free space is checked (the files plus 32 MiB); short, the install fails with
///   `NOT_ENOUGH_STORAGE` and the bytes it asked for.
/// - After the fetch every file is checked against the manifest; a mismatch is `FILE_CHECK_FAILED` and the folder is
///   removed so the next install fetches it again.
/// - The status is stored: the last check or install, refreshed by `refresh()`; a failure stays until the next install.
public actor SpeakerModelInstaller {
    /// Fetches the manifest's files into `directory/<folder>`, reporting the fraction done (nil while unknown).
    public typealias Fetch = @Sendable (_ directory: URL, _ progress: @escaping @Sendable (Double?) -> Void) async throws -> Void

    /// The install that runs: its task, the callers waiting on it and their progress callbacks.
    private struct Install {
        let number: Int
        let task: Task<Void, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var listeners: [UUID: @Sendable (Double?) -> Void] = [:]
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
        if let current { return try await wait(on: current.number, progress: progress) }
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
        let number = start(removingFirst: check == .mismatch)
        try await wait(on: number, progress: progress)
    }

    private func start(removingFirst stale: Bool) -> Int {
        stored = .downloading(nil)
        fetches += 1
        let number = fetches
        let directory = directory, manifest = manifest, network = network, fetch = fetch
        let task = Task.detached {
            try await Self.run(fetch, into: directory, manifest: manifest, network: network, removingFirst: stale) { fraction in
                Task { await self.report(fraction, for: number) }
            } checking: {
                await self.reportChecking(for: number)
            }
        }
        current = Install(number: number, task: task)
        Task {
            let result = await task.result
            self.finish(number, result)
        }
        return number
    }

    /// The fetch and the check of one install, off the actor; every failure is a `SpeakerAnalysisError` or a cancel.
    private static func run(_ fetch: Fetch, into directory: URL, manifest: SpeakerModelManifest, network: ModelNetworkGate,
                            removingFirst stale: Bool, progress: @escaping @Sendable (Double?) -> Void,
                            checking: @Sendable () async -> Void) async throws {
        let folder = directory.appendingPathComponent(manifest.folder, isDirectory: true)
        do {
            if stale { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await network.allowingDownloads { try await fetch(directory, progress) }
            try Task.checkCancellation()
            await checking()
            guard manifest.check(in: directory) == .ready else {
                try? FileManager.default.removeItem(at: folder)
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
            }
        } onCancel: {
            Task { await self.leave(number, id) }
        }
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
        guard let current, current.number == number, current.waiters.isEmpty else { return }
        current.task.cancel()
    }

    private func report(_ fraction: Double?, for number: Int) {
        guard let current, current.number == number else { return }
        if case .checking = stored { return }
        stored = .downloading(fraction.map { min(max($0, 0), 1) })
        for listener in current.listeners.values { listener(fraction) }
    }

    private func reportChecking(for number: Int) {
        guard current?.number == number else { return }
        stored = .checking
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
