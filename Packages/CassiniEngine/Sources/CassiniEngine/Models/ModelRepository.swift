import Foundation
import Synchronization
import CassiniNotebook

/// What Settings and the Model download screen show for one `ModelPart` (Android's `ModelStatus`).
public enum ModelStatus: Hashable, Sendable {
    case ready
    /// Not installed. `consented`: "Downloads with next transcription"; otherwise "Not downloaded".
    case missing(consented: Bool)
    /// `bytes` of the part's `total` download bytes are here.
    case downloading(percent: Int, bytes: Int64, total: Int64)
    /// "Checking files": the downloaded files are being verified.
    case verifying(percent: Int)
    /// The last install of this part failed; it tries again next time. `detail` is a diagnostic, never shown.
    case failed(JobFailure, detail: String?)

    /// Whether this is the progress of an install (downloading, verifying or failed) rather than a readiness.
    public var isProgress: Bool {
        switch self {
        case .ready, .missing: false
        case .downloading, .verifying, .failed: true
        }
    }
}

/// The result of `ModelRepository.install`. `skipped` lists best-effort models that failed to install.
public struct InstallResult: Hashable, Sendable {
    public var part: ModelPart
    public var skipped: [ModelDescriptor]
    public init(part: ModelPart, skipped: [ModelDescriptor]) { self.part = part; self.skipped = skipped }
}

/// Fetches the files of one model into its directory (Android's `ModelFetcher`). Tests pass a fake; the app uses
/// `NetworkModelFetcher`.
public protocol ModelFetching: Sendable {
    /// Installs `model`'s artifacts in `directory`, verified. `progress` gets the bytes of the model's download done
    /// so far and whether they are being checked rather than downloaded. Fails with a `ModelError`.
    func fetch(_ model: ModelDescriptor, into directory: URL,
               progress: @escaping @Sendable (Int64, Bool) -> Void) async throws
}

/// `ArtifactFetcher` with Range resume, following only the redirects `redirects` allows. `url` says where each
/// artifact comes from. A compressed download needs `decoder`; without one it fails with `INSTALL`.
public struct NetworkModelFetcher: ModelFetching {
    public let fetcher: ArtifactFetcher
    public let redirects: RedirectPolicy
    public let decoder: (any Decompressing)?
    private let url: @Sendable (Artifact) -> String

    public init(fetcher: ArtifactFetcher, redirects: RedirectPolicy = .downloads, decoder: (any Decompressing)? = nil,
                url: @escaping @Sendable (Artifact) -> String = { $0.url }) {
        self.fetcher = fetcher; self.redirects = redirects; self.decoder = decoder; self.url = url
    }

    public func fetch(_ model: ModelDescriptor, into directory: URL,
                      progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        if let download = model.download {
            guard let decoder, let artifact = model.artifacts.first, model.artifacts.count == 1 else {
                throw ModelError(.modelInstall, "No decoder for \(download.name)")
            }
            try await fetcher.fetchCompressed(url(download), download: download, artifact: artifact, into: directory,
                                              decoder: decoder, redirects: redirects, progress: progress)
            return
        }
        var completed: Int64 = 0
        for artifact in model.artifacts {
            let done = completed
            try await fetcher.fetch(url(artifact), artifact, into: directory, redirects: redirects) { bytes, verifying in
                progress(done + bytes, verifying)
            }
            completed += artifact.size
        }
    }
}

/// Where the speech consent is stored (`models.consentAt` and `models.declinedAt`); `SettingsStore` in the app.
public protocol ModelConsentRecords: Sendable {
    func consentAt() async -> Date?
    /// "Download and transcribe" or "Download" was pressed.
    func recordConsent() async
    /// "Not now — keep the audio" was pressed.
    func recordDeclined() async
}

/// The models Cassini installs itself (Android's `ModelRepository`): which parts are installed under `root`, consent,
/// the install plan and the install itself. `status` combines the readiness on disk (read by `refresh`) with the
/// progress of an install in flight, which `install` and `PinnedModelInstaller` push. It is empty until the first
/// `refresh`. `onChange` receives every new status.
///
/// Consent is `models.consentAt` present or Parakeet installed, so a time recorded for Apple's speech assets still
/// counts. It is recorded only by `recordConsent` (the Model download screen's primary button); callers check
/// `consented()` before any install, and `install` does not.
///
/// The root is excluded from backups once an install creates it.
public final class ModelRepository: Sendable {
    private struct State {
        var ready: [ModelPart: Bool] = [:]
        var consentRecorded = false
        var inFlight: [ModelPart: ModelStatus] = [:]
        var status: [ModelPart: ModelStatus] = [:]
    }

    public let root: URL
    private let consent: any ModelConsentRecords
    private let fetcher: any ModelFetching
    private let onChange: @Sendable ([ModelPart: ModelStatus]) -> Void
    private let state = Mutex(State())

    public init(root: URL, consent: any ModelConsentRecords, fetcher: any ModelFetching,
                onChange: @escaping @Sendable ([ModelPart: ModelStatus]) -> Void = { _ in }) {
        self.root = root; self.consent = consent; self.fetcher = fetcher; self.onChange = onChange
    }

    public var status: [ModelPart: ModelStatus] { state.withLock { $0.status } }

    /// Reads the readiness of every part and the consent again, and returns the new `status`.
    @discardableResult public func refresh() async -> [ModelPart: ModelStatus] {
        let recorded = await consent.consentAt() != nil
        let readiness = readiness()
        return update { state in
            state.consentRecorded = recorded
            state.ready = readiness
            // A failure is shown until the part is installed or a new install starts.
            state.inFlight = state.inFlight.filter { readiness[$0.key] != true }
        }
    }

    /// `models.consentAt` present or Parakeet installed.
    public func consented() async -> Bool {
        if await consent.consentAt() != nil { return true }
        return ModelCatalog.parakeet.ready(in: root)
    }

    public func recordConsent() async {
        await consent.recordConsent()
        await refresh()
    }

    public func recordDeclined() async { await consent.recordDeclined() }

    /// What a download still has to install, with sizes and the free space it needs.
    public func plan() -> ModelPlan { ModelPlan.of(root: root) }

    public func ready(_ part: ModelPart) -> Bool { part.primary.ready(in: root) }

    /// Progress of an install that `PinnedModelInstaller` runs or waits for (downloading, verifying or failed);
    /// shown until `clearProgress`, the end of an install, or a `refresh` that finds the part installed. A readiness
    /// is no progress: it is refused, and false comes back.
    @discardableResult public func publishProgress(_ part: ModelPart, _ progress: ModelStatus) -> Bool {
        guard progress.isProgress else { return false }
        update { $0.inFlight[part] = progress }
        return true
    }

    /// Drops the progress of `part`, so it shows its readiness again (a cancelled install).
    public func clearProgress(_ part: ModelPart) {
        update { $0.inFlight[part] = nil }
    }

    /// Installs the models of `part` that are not ready, through the fetcher, and pushes the progress into `status`
    /// and to `progress`. Each model's marker is deleted first and written only after all of its files verified. The
    /// primary model is required: its failure ends the install with its `ModelError` (CANCELLED when the task was
    /// cancelled). An extra (the speech detector) is best effort: its failure is logged and listed in
    /// `InstallResult.skipped`.
    public func install(_ part: ModelPart,
                        progress: @escaping @Sendable (ModelStatus) -> Void = { _ in }) async throws -> InstallResult {
        let todo = part.models.filter { !$0.ready(in: root) }
        let total = max(todo.reduce(0) { $0 + $1.downloadBytes }, 1)
        var skipped: [ModelDescriptor] = []
        var completed: Int64 = 0
        do {
            for model in todo {
                let done = completed
                let installed = try await installOne(part, model) { [self] bytes, verifying in
                    let status = Self.progressOf(done + bytes, total, verifying)
                    publishProgress(part, status)
                    progress(status)
                }
                if !installed { skipped.append(model) }
                completed += model.downloadBytes
            }
        } catch {
            update { state in
                if let failure = error as? ModelError, failure.failure != .cancelled {
                    state.inFlight[part] = .failed(failure.failure, detail: failure.message)
                } else if error is ModelError || ModelInstaller.isCancellation(error) {
                    state.inFlight[part] = nil
                } else if case .failed? = state.inFlight[part] {
                    // Any other failure must not leave a download showing forever.
                } else {
                    state.inFlight[part] = nil
                }
            }
            throw error
        }
        let ready = part.primary.ready(in: root)
        update { state in
            state.inFlight[part] = nil
            state.ready[part] = ready
        }
        progress(.ready)
        return InstallResult(part: part, skipped: skipped)
    }

    /// Installs one `model` through the fetcher, with no status update: deletes its marker, fetches and verifies its
    /// files (resuming `.part` files), then writes the marker. `progress` gets the bytes of the model's download and
    /// whether they are being checked. Any failure is thrown as a `ModelError` (a full disk becomes SPACE, any other
    /// file or network error DOWNLOAD), or as `CancellationError`.
    public func installModel(_ model: ModelDescriptor,
                             progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        try prepareRoot()
        let directory = model.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(model.markerFile)
        try? FileManager.default.removeItem(at: marker)
        do {
            try await fetcher.fetch(model, into: directory, progress: progress)
        } catch let error as ModelError {
            throw error
        } catch {
            if ModelInstaller.isCancellation(error) { throw error }
            // iOS reports a full disk as its own error: NOT_ENOUGH_STORAGE, where Android reads it as an I/O error.
            if CheckpointFiles.isOutOfSpace(error) { throw ModelError(.space, "\(error)") }
            throw ModelError(.modelDownload, "\(error)")
        }
        do {
            try Data(model.markerValue.utf8).write(to: marker, options: .atomic)
        } catch {
            throw ModelError(.modelInstall, "\(error)")
        }
    }

    /// Creates the root, excluded from backups: the models download again.
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = root
        try? root.setResourceValues(values)
    }

    /// Installs one model; false when a best-effort extra failed (and was skipped).
    private func installOne(_ part: ModelPart, _ model: ModelDescriptor,
                            progress: @escaping @Sendable (Int64, Bool) -> Void) async throws -> Bool {
        do {
            try await installModel(model, progress: progress)
            return true
        } catch {
            if model == part.primary || ModelInstaller.isCancellation(error) { throw error }
            Self.log("Skipped \(model.directory)/\(model.markerFile): \(error)")
            return false
        }
    }

    private func readiness() -> [ModelPart: Bool] {
        ModelPart.allCases.reduce(into: [:]) { $0[$1] = $1.primary.ready(in: root) }
    }

    /// Applies `change` and publishes the status from the fields. A part whose readiness is unknown is left out.
    @discardableResult private func update(_ change: (inout State) -> Void) -> [ModelPart: ModelStatus] {
        let next = state.withLock { state in
            change(&state)
            let consent = state.consentRecorded || state.ready[.speech] == true
            var next: [ModelPart: ModelStatus] = [:]
            for part in ModelPart.allCases {
                if let progress = state.inFlight[part] {
                    next[part] = progress
                } else if let ready = state.ready[part] {
                    next[part] = ready ? .ready : .missing(consented: consent)
                }
            }
            state.status = next
            return next
        }
        onChange(next)
        return next
    }

    static func progressOf(_ bytes: Int64, _ total: Int64, _ verifying: Bool) -> ModelStatus {
        let done = min(max(bytes, 0), total)
        let percent = Int(done * 100 / total)
        return verifying ? .verifying(percent: percent) : .downloading(percent: percent, bytes: done, total: total)
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("ModelRepository: \(message)")
        #endif
    }
}

/// `ModelStore` over a `ModelRepository` (Android's `RepositoryModelStore`): consent read once when the install
/// starts, the network from `online`, the free space from `storage`.
public struct RepositoryModelStore: ModelStore {
    private let models: ModelRepository
    private let storage: any StorageProbe
    private let online: @Sendable () -> Bool
    private let consent: Bool

    public init(models: ModelRepository, storage: any StorageProbe, online: @escaping @Sendable () -> Bool,
                consented: Bool) {
        self.models = models; self.storage = storage; self.online = online; self.consent = consented
    }

    public func consented() async -> Bool { consent }
    public func hasValidatedNetwork() -> Bool { online() }
    public func ready(_ model: ModelDescriptor) -> Bool { model.ready(in: models.root) }
    public func usableBytes() -> Int64 { storage.availableBytes(at: models.root) }
    public func install(_ model: ModelDescriptor, progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        try await models.installModel(model, progress: progress)
    }
}
