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

/// Fetches the files of one model into a directory (Android's `ModelFetcher`). Tests pass a fake; the app uses
/// `NetworkModelFetcher`.
public protocol ModelFetching: Sendable {
    /// Places `model`'s artifacts, verified, and the model host's `NOTICE.txt` in `directory` (the model's staging
    /// directory). `progress` gets the bytes of the model's download done so far and whether they are being checked
    /// rather than downloaded. Fails with a `ModelError`.
    func fetch(_ model: ModelDescriptor, into directory: URL,
               progress: @escaping @Sendable (Int64, Bool) -> Void) async throws
}

/// Downloads from the model host only (D4, D53.1; Android's `ModelFetcher.network`). First reads the host's manifest
/// and finds the model's pinned pair and files in it (`DistManifest.urls`): a manifest that does not list them as
/// pinned refuses the download with `PIN_UNAVAILABLE` before any file is fetched. Then the host's notices go into the
/// directory, and each file is fetched as its own seekable Zstandard object with `ArtifactFetcher.fetchCompressed`
/// (Range and If-Range resume, verified before and after decompression), following only the redirects `redirects`
/// allows (HTTPS to `ModelCatalog.downloadHosts`, at most five hops).
///
/// The progress counts the compressed bytes of every file. Only the last file's check reports as checking: the files
/// before it are checked while the progress stays at their end, so the status does not go back and forth between
/// downloading and checking for each file.
public struct NetworkModelFetcher: ModelFetching {
    public let fetcher: ArtifactFetcher
    public let redirects: RedirectPolicy
    public let decoder: (any Decompressing)?
    public let manifestURL: String
    public let noticeURL: String
    /// The origin the manifest must name (`base_url`).
    public let base: String

    public init(fetcher: ArtifactFetcher, redirects: RedirectPolicy = .downloads, decoder: (any Decompressing)? = nil,
                manifestURL: String = ModelCatalog.manifestURL, noticeURL: String = ModelCatalog.noticeURL,
                base: String = ModelCatalog.distBase) {
        self.fetcher = fetcher; self.redirects = redirects; self.decoder = decoder
        self.manifestURL = manifestURL; self.noticeURL = noticeURL; self.base = base
    }

    public func fetch(_ model: ModelDescriptor, into directory: URL,
                      progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        guard let decoder else { throw ModelError(.modelInstall, "No Zstandard decoder") }
        var activeFetcher = fetcher
        let urls: [String: String]
        do {
            urls = try await metadata(model, into: directory, using: activeFetcher)
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: "metadata.initial", error: error)
            guard !ModelInstaller.isCancellation(error),
                  let network = error as? URLError,
                  network.code == .timedOut || network.code == .networkConnectionLost,
                  let fresh = fetcher.transport.freshForRetry() else { throw error }
            try Task.checkCancellation()
            activeFetcher = ArtifactFetcher(transport: fresh, storage: fetcher.storage)
            ModelInstallDiagnostics.begin(model: model.id, stage: "metadata.retry")
            do {
                // Re-read both metadata objects and repeat pin/redirect checks using the independent transport session.
                urls = try await metadata(model, into: directory, using: activeFetcher)
            } catch {
                ModelInstallDiagnostics.failure(model: model.id, stage: "metadata.retry", error: error)
                throw error
            }
        }
        var completed: Int64 = 0
        for (index, artifact) in model.artifacts.enumerated() {
            guard let download = artifact.download, let url = urls[artifact.name] else {
                throw ModelError(.modelInstall, "\(artifact.name) has no pinned download")
            }
            let done = completed, last = index == model.artifacts.count - 1
            try await activeFetcher.fetchCompressed(url, download: download, artifact: artifact, into: directory,
                                              decoder: decoder, redirects: redirects) { bytes, verifying in
                if verifying && !last {
                    progress(done + download.size, false)
                } else {
                    progress(done + bytes, verifying)
                }
            }
            completed += download.size
        }
    }

    /// The model's metadata-retry scope: no artifact bytes have been requested yet.
    /// ArtifactFetcher separately bounds recovery of an artifact GET that fails before response headers arrive.
    private func metadata(_ model: ModelDescriptor, into directory: URL,
                          using fetcher: ArtifactFetcher) async throws -> [String: String] {
        let urls: [String: String]
        do {
            ModelInstallDiagnostics.begin(model: model.id, stage: "manifest")
            urls = try await manifest(using: fetcher).urls(model, allowed: redirects)
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: "manifest", error: error)
            throw error
        }
        try await fetcher.fetchNotice(noticeURL, into: directory, redirects: redirects)
        return urls
    }

    /// The host's manifest. One that is too long cannot be the host's: it is refused as a model the host does not
    /// offer, not as a damaged download.
    private func manifest(using fetcher: ArtifactFetcher) async throws -> DistManifest {
        let data: Data
        do {
            data = try await fetcher.read(manifestURL, limit: DistManifest.maxBytes, redirects: redirects)
        } catch let error as ModelError where error.failure == .modelVerify {
            throw ModelError(.download(.pinUnavailable), "Manifest: \(error.message)")
        }
        return try DistManifest.parse(data, base: base)
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
///
/// Layout (D4): `<root>/models/<id>/<source_sha256>/` holds a model's files and the host's `NOTICE.txt`. An install
/// collects them in `<root>/models/<id>/.<source_sha256>.staging/`, which keeps `.part` files and checked files
/// across failures and app kills, then renames it into place; a broken revision is retired by renaming it to
/// `.remove-<UUID>` before it is deleted. `prune` deletes everything else.
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
    /// The per-session check of the installed models (`ModelVerifier`).
    public let verifier: ModelVerifier
    private let onChange: @Sendable ([ModelPart: ModelStatus]) -> Void
    private let state = Mutex(State())

    /// `verifier` learns of each install, which has just checked every file.
    public init(root: URL, consent: any ModelConsentRecords, fetcher: any ModelFetching,
                verifier: ModelVerifier = .shared,
                onChange: @escaping @Sendable ([ModelPart: ModelStatus]) -> Void = { _ in }) {
        self.root = root; self.consent = consent; self.fetcher = fetcher; self.verifier = verifier
        self.onChange = onChange
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
    /// and to `progress`. Each model's revision appears only once all of its files verified. The primary model is required: its failure ends the install with its `ModelError` (CANCELLED when the task was
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
                if let failure = error as? ModelError, !ModelInstaller.isCancellation(failure) {
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

    /// Installs one `model` through the fetcher, with no status update. A revision directory that is there but not
    /// complete is retired first. The fetcher fills the model's staging directory (resuming its `.part` files and
    /// keeping the files it checked before); once every file and the notices are there, the staging directory is
    /// written through to storage, renamed into place (never over an existing directory) and its parent written
    /// through. `progress` gets the bytes of the model's download and whether they are being checked. Any failure is
    /// thrown as a `ModelError` (a full disk becomes SPACE, other file errors INSTALL, network errors DOWNLOAD), or as
    /// `CancellationError`; the staging directory stays for the next attempt.
    public func installModel(_ model: ModelDescriptor,
                             progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        var stage = "prepare-root"
        do {
            ModelInstallDiagnostics.begin(model: model.id, stage: stage)
            try prepareRoot()
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: stage, error: error)
            throw Self.localFailure(error)
        }
        let final = model.directory(in: root)
        if model.ready(in: root) { return }
        let staging = model.staging(in: root)
        do {
            stage = "retire"
            ModelInstallDiagnostics.begin(model: model.id, stage: stage)
            try ModelFiles.retire(final)
            stage = "staging"
            ModelInstallDiagnostics.begin(model: model.id, stage: stage)
            try Self.prepareDirectory(staging)
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: stage, error: error)
            throw Self.localFailure(error)
        }
        do {
            try await fetcher.fetch(model, into: staging, progress: progress)
        } catch let error as ModelError {
            ModelInstallDiagnostics.failure(model: model.id, stage: "artifact-fetch", error: error)
            throw error
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: "artifact-fetch", error: error)
            if ModelInstaller.isCancellation(error) { throw error }
            // iOS reports a full disk as its own error: NOT_ENOUGH_STORAGE, where Android reads it as an I/O error.
            if CheckpointFiles.isOutOfSpace(error) { throw ModelError(.space, "\(error)") }
            if (error as NSError).domain == NSURLErrorDomain {
                let code = (error as? URLError)?.code ?? URLError.Code(rawValue: (error as NSError).code)
                throw ModelError(.modelDownload, "\(error)", urlErrorCode: code)
            }
            throw Self.localFailure(error)
        }
        try ModelError.require(!Task.isCancelled, .cancelled)
        guard model.complete(staging) else {
            let error = ModelError(.modelInstall, "\(model.pin) is incomplete")
            ModelInstallDiagnostics.failure(model: model.id, stage: "complete", error: error)
            throw error
        }
        stage = "remove-leftovers"
        do {
            try Self.removeLeftovers(of: model, in: staging)
            stage = "staging-directory-sync"
            ModelInstallDiagnostics.begin(model: model.id, stage: stage)
            try ModelFiles.sync(staging)
            try ModelError.require(!Task.isCancelled, .cancelled)
            stage = "revision-rename"
            ModelInstallDiagnostics.begin(model: model.id, stage: stage)
            try ModelFiles.renameExclusive(staging, final)
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: stage, error: error)
            if ModelInstaller.isCancellation(error) { throw error }
            throw Self.localFailure(error)
        }
        // The verified revision is already published. A directory flush failure cannot unpublish it.
        do {
            ModelInstallDiagnostics.begin(model: model.id, stage: "parent-directory-sync")
            try ModelFiles.sync(final.deletingLastPathComponent())
        } catch {
            ModelInstallDiagnostics.failure(model: model.id, stage: "parent-directory-sync", error: error)
        }
        verifier.markVerified(model, in: root)
    }

    /// Deletes what is left in a complete staging directory besides the model's files and notices (the `.part` of a
    /// file that verified on another attempt).
    private static func removeLeftovers(of model: ModelDescriptor, in staging: URL) throws {
        let keep = Set(model.artifacts.map(\.name) + [ModelDescriptor.noticeFile])
        for name in try FileManager.default.contentsOfDirectory(atPath: staging.path) where !keep.contains(name) {
            try FileManager.default.removeItem(at: staging.appendingPathComponent(name))
        }
    }

    /// Deletes everything under the root that no model of the catalog reads: the directories of earlier development
    /// builds (`parakeet-ultra/`, `vad/`, `speaker-models/`; D51, nothing is migrated), the revisions and staging
    /// directories of other pins, ids the catalog no longer has, and retired revisions. A model's pinned revision and
    /// its staging directory stay, so this can run beside an install. D86's legacy Parakeet id also stays until
    /// `ModelVerifier` verifies its replacement and retires the old install.
    public func prune() { Self.prune(root: root) }

    /// `prune` for the model root `root`.
    public static func prune(root: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for name in entries where name != ModelDescriptor.modelsDirectory {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
        let models = root.appendingPathComponent(ModelDescriptor.modelsDirectory, isDirectory: true)
        let pinned = Dictionary(ModelCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in (try? manager.contentsOfDirectory(atPath: models.path)) ?? [] {
            let directory = models.appendingPathComponent(id, isDirectory: true)
            // Existing files and a complete-looking replacement are not proof that the new model verified.
            if id == ModelCatalog.legacyParakeet.id { continue }
            guard let model = pinned[id] else {
                try? manager.removeItem(at: directory)
                continue
            }
            let keep: Set<String> = [model.sourceSha256, ".\(model.sourceSha256).staging"]
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(name) {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Model work may finish after auto-lock. Apply protection even when upgrading an existing staging directory.
    static func prepareDirectory(_ directory: URL, using files: FileManager = .default) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try files.setAttributes(protection, ofItemAtPath: directory.path)
        // Existing partials keep their old class when only their directory changes. Migrate those too before a
        // resumed install can continue under auto-lock; new files inherit the directory's policy.
        for child in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            if try child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                try files.setAttributes(protection, ofItemAtPath: child.path)
            }
        }
    }

    private static func localFailure(_ error: any Error) -> ModelError {
        ModelError(CheckpointFiles.isOutOfSpace(error) ? .space : .modelInstall, "\(error)")
    }

    /// Creates the root, excluded from backups: the models download again.
    private func prepareRoot() throws {
        try Self.prepareDirectory(root)
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
            Self.log("Skipped \(model.pin): \(error)")
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
