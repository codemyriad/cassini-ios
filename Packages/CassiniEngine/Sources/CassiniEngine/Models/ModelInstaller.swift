import Foundation
import CassiniNotebook

/// The model files `ModelInstaller` installs into (Android's `ModelStore`), implemented over `ModelRepository` by
/// `RepositoryModelStore`.
public protocol ModelStore: Sendable {
    /// Consent recorded, or Parakeet installed.
    func consented() async -> Bool
    /// Whether the device has a usable network path now.
    func hasValidatedNetwork() -> Bool
    /// Whether `model` is installed (its revision directory is complete).
    func ready(_ model: ModelDescriptor) -> Bool
    /// Free bytes where the models are installed.
    func usableBytes() -> Int64
    /// Installs `model` through `ArtifactFetcher` with Range resume: fetches and verifies each file into the model's
    /// staging directory, then renames it into place. `progress` receives a count in bytes of `model`'s download (0 to
    /// `model.downloadBytes`) and whether it is verifying. Throws what `ArtifactFetcher` throws.
    func install(_ model: ModelDescriptor, progress: @escaping @Sendable (Int64, Bool) -> Void) async throws
}

/// How a `ModelInstaller.install` call ended.
public enum InstallOutcome: Hashable, Sendable {
    /// Speech recognition is ready, if it was asked for. Best-effort parts that are still missing are in `skipped`
    /// (no network, or voices without the diarizer: nothing was fetched) or in `failed` with the reason. They never
    /// fail a job: it degrades to one voice or no names.
    case installed(skipped: Set<ModelPart> = [], failed: [ModelPart: DownloadError] = [:])
    /// The required `part` could not be installed. `requiredFreeBytes` is the space figure for NOT_ENOUGH_STORAGE:
    /// what `part` alone needs.
    case failed(part: ModelPart, error: DownloadError, requiredFreeBytes: Int64)
    /// No consent: nothing was fetched and no network call made. `missingBytes` is what the download would fetch.
    case needsConsent(missingBytes: Int64)
}

/// Installs model parts in `ModelPart` order (Android's `ModelInstaller`). `PinnedModelInstaller` is its only caller;
/// jobs and the standalone download share it.
///
/// - Speech is required: Parakeet must install. Its speech detector (VAD) is best effort, also when Parakeet is
///   already installed.
/// - Speakers (the diarizer) is best effort.
/// - Voices (the voiceprint model) is best effort, and only installed once the diarizer is: prints come from the
///   diarizer's speakers.
/// - Without a network the best-effort parts are skipped at once (no 30 s timeout). Speech is still tried: the check
///   can be stale, and its failure says "No connection".
/// - Consent is checked again on entry: without it nothing is fetched.
/// - Free space is checked before the first byte of each part, against that part's `ModelPlan.requiredFreeBytes` and
///   the space free at that time. A best-effort part without room goes into `failed` with NOT_ENOUGH_STORAGE.
///
/// Cancelling the caller cancels the fetch, which keeps its `.part` files, and ends in `CancellationError`.
public struct ModelInstaller: Sendable {
    private let store: any ModelStore

    public init(store: any ModelStore) { self.store = store }

    /// Installs the missing models of `parts`.
    public func install(_ parts: Set<ModelPart>,
                        onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> InstallOutcome {
        let missing = ModelPlan.of(ready: store.ready).missing.filter { parts.contains($0.part) }
        // A Parakeet installed earlier without its detector: the detector alone is fetched (best effort).
        let speechMissing = missing.contains { $0.part == .speech }
        let detectorOnly = parts.contains(.speech) && !speechMissing && !store.ready(ModelCatalog.vad)
        if missing.isEmpty && !detectorOnly { return .installed() }
        // Parakeet installed means consent, so a refusal here always has something missing to report.
        guard await store.consented() else { return .needsConsent(missingBytes: ModelPlan(missing).totalBytes) }
        return try await installMissing(missing, detectorOnly: detectorOnly, onProgress: onProgress)
    }

    private func installMissing(_ missing: [ModelPlan.Item], detectorOnly: Bool,
                                onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> InstallOutcome {
        let online = store.hasValidatedNetwork()
        let attempted = missing.filter { $0.part == .speech || online }
        var skipped = Set(missing.map(\.part).filter { part in !attempted.contains { $0.part == part } })
        var failed: [ModelPart: DownloadError] = [:]
        // Speech comes first; when it fails nothing else is tried. A failed best-effort part does not stop the next.
        var speechError: DownloadError?
        var speechFreeBytes: Int64 = 0
        for item in attempted {
            if speechError != nil { break }
            try Task.checkCancellation()
            // Each part is checked against what is free now, after the parts installed before it.
            let requiredFreeBytes = ModelPlan([item]).requiredFreeBytes
            let space = store.usableBytes() >= requiredFreeBytes
            let error = space ? try await attempt(item, &skipped, onProgress) : .notEnoughStorage
            if item.part == .speech {
                speechError = error
                speechFreeBytes = requiredFreeBytes
            } else if let error {
                failed[item.part] = error
            }
        }
        if speechError == nil && online && detectorOnly {
            _ = try await installPart(ModelPlan.Item(.speech, [ModelCatalog.vad]), onProgress)
        }
        if let speechError { return .failed(part: .speech, error: speechError, requiredFreeBytes: speechFreeBytes) }
        return .installed(skipped: skipped, failed: failed)
    }

    /// Installs `item`, unless it is voices and the diarizer is missing: then it joins `skipped`.
    private func attempt(_ item: ModelPlan.Item, _ skipped: inout Set<ModelPart>,
                         _ onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadError? {
        if item.part == .voices && !store.ready(ModelCatalog.diarization) {
            skipped.insert(item.part)
            return nil
        }
        return try await installPart(item, onProgress)
    }

    /// Installs `item`'s models in order. Returns nil when the part's primary model is ready afterwards, else why
    /// not. A failed extra (the detector) is ignored. Cancellation is thrown, never returned.
    private func installPart(_ item: ModelPlan.Item,
                             _ onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadError? {
        let total = item.downloadBytes
        var completed: Int64 = 0
        for model in item.models {
            try Task.checkCancellation()
            let done = completed
            var failure: DownloadError?
            do {
                try await store.install(model) { bytes, verifying in
                    let bytes = done + min(max(bytes, 0), model.downloadBytes)
                    onProgress(DownloadProgress(part: item.part, doneBytes: bytes, totalBytes: total, verifying: verifying))
                }
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                failure = Self.downloadError(error, online: store.hasValidatedNetwork)
            }
            if let failure, model == item.part.primary { return failure }
            completed += model.downloadBytes
        }
        return nil
    }

    /// Whether `error` (or the task) is a cancellation rather than a failure.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if let error = error as? ModelError { return error.failure == .cancelled || error.urlErrorCode == .cancelled }
        if let error = error as? URLError { return error.code == .cancelled }
        return false
    }

    /// The banner a download failure shows (Android's `ModelInstaller.downloadError`). A DOWNLOAD failure or a
    /// network error reads NO_CONNECTION when `online` says there is no network, INTERRUPTED when there is; a timeout,
    /// an unknown host or a refused connection is always NO_CONNECTION. A redirect outside the allow-list
    /// (`RedirectPolicy` reports "… is not allowed") is HOST_NOT_ALLOWED. SPACE, VERIFY and INSTALL map to their own
    /// errors; a full disk is NOT_ENOUGH_STORAGE (iOS reports it as its own error); a model the host's manifest does
    /// not offer as pinned (`DistManifest`) is PIN_UNAVAILABLE (iOS only); anything else did not finish installing.
    public static func downloadError(_ failure: any Error, online: () -> Bool) -> DownloadError {
        if let failure = failure as? ModelError {
            switch failure.failure {
            case .download(let error): return error
            case .space: return .notEnoughStorage
            case .modelVerify: return .fileCheckFailed
            case .modelDownload:
                if failure.message.hasSuffix(RedirectPolicy.refusedSuffix) { return .hostNotAllowed }
                if let code = failure.urlErrorCode { return transportError(code, online: online) }
                return online() ? .interrupted : .noConnection
            default: return .install
            }
        }
        if let failure = failure as? URLError { return transportError(failure.code, online: online) }
        if CheckpointFiles.isOutOfSpace(failure) { return .notEnoughStorage }
        let error = failure as NSError
        if error.domain == NSPOSIXErrorDomain || (error.domain == NSCocoaErrorDomain && error.code >= 256 && error.code < 1024) {
            // Android's IOException: a read or write that failed.
            return online() ? .interrupted : .noConnection
        }
        return .install
    }

    /// The same transport failure has the same user-facing meaning before and after repository wrapping.
    private static func transportError(_ code: URLError.Code, online: () -> Bool) -> DownloadError {
        switch code {
        case .timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet,
             .dataNotAllowed, .internationalRoamingOff:
            return .noConnection
        default:
            return online() ? .interrupted : .noConnection
        }
    }

}
