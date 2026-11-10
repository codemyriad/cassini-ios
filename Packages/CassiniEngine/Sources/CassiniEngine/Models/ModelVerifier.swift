import Foundation
import Synchronization
import CassiniNotebook

/// The check of an installed model before its first use in each session (D16 §4: "before the first load in each app
/// session, verify the installed files against their pinned uncompressed_sha256"), for every model of the catalog.
///
/// - The first `verify` of a model in this process hashes every file of its revision against the pins. A model that
///   passes is not hashed again until the process ends.
/// - An install that just published the revision has hashed every file (`ArtifactFetcher`), so it counts as checked
///   (`markVerified`).
/// - A file that differs retires the whole revision (renamed, then deleted, so no half of it is read as a model) and
///   `verify` returns false: the model reads as not installed.
/// - The check stops between blocks once `cancelled` is true, with `CancellationError`; it is not recorded, so the next
///   use checks again. The caller runs it where the model will load (the inference thread) with its cancel flag, never
///   on the Swift cooperative pool: Parakeet is 670 MB.
public final class ModelVerifier: Sendable {
    /// Hashes a file: its hex SHA-256, checking `cancelled` between blocks and passing the bytes read to `onBytes`.
    public typealias Digest = @Sendable (URL, _ cancelled: () -> Bool, _ onBytes: (Int64) -> Void) throws -> String

    /// The process's verifier: a session is the life of the process.
    public static let shared = ModelVerifier()

    private struct CheckedModel: Hashable, Sendable {
        let root: String
        let model: ModelDescriptor
    }

    private let checked = Mutex<Set<CheckedModel>>([])
    private let digest: Digest

    public init(digest: @escaping Digest = { file, cancelled, onBytes in
        try ArtifactFetcher.digest(file, onBytes: onBytes, cancelled: cancelled)
    }) {
        self.digest = digest
    }

    private static func key(_ model: ModelDescriptor, _ root: URL) -> CheckedModel {
        CheckedModel(root: root.standardizedFileURL.path, model: model)
    }

    /// Whether `model` under `root` was checked, or installed, in this session.
    public func isChecked(_ model: ModelDescriptor, in root: URL) -> Bool {
        checked.withLock { $0.contains(Self.key(model, root)) }
    }

    /// Records that every file of `model` under `root` was just checked, as an install does.
    public func markVerified(_ model: ModelDescriptor, in root: URL) {
        guard model.ready(in: root) else { return }
        _ = checked.withLock { $0.insert(Self.key(model, root)) }
        retireReplacedParakeet(afterVerifying: model, in: root)
    }

    /// Forgets the checks, as a new session would.
    public func reset() { checked.withLock { $0.removeAll() } }

    /// True when `model` is installed under `root` and every file matches its pins, checked once a session; false when
    /// it is not installed, or when a file differs (its revision is then retired). `onBytes` receives the bytes hashed
    /// so far out of `model.artifactBytes`. Throws `CancellationError` when `cancelled` turns true, and a file that
    /// cannot be read throws its error and retires nothing.
    public func verify(_ model: ModelDescriptor, in root: URL, onBytes: (Int64) -> Void = { _ in },
                       cancelled: () -> Bool = { false }) throws -> Bool {
        guard model.ready(in: root) else { return false }
        if cancelled() { throw CancellationError() }
        if isChecked(model, in: root) {
            // A failed best-effort retirement is tried again without hashing the new files again.
            retireReplacedParakeet(afterVerifying: model, in: root)
            return true
        }
        let directory = model.directory(in: root)
        var done: Int64 = 0
        for artifact in model.artifacts {
            if cancelled() { throw CancellationError() }
            let file = directory.appendingPathComponent(artifact.name)
            let hash: String
            do {
                let before = done
                hash = try digest(file, cancelled) { onBytes(before + $0) }
            } catch let error as ModelError where error.failure == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            }
            if cancelled() { throw CancellationError() }
            guard hash == artifact.sha256 else {
                Self.log("\(model.pin): \(artifact.name) does not match its pin; the revision is removed")
                try? ModelFiles.retire(directory)
                return false
            }
            done += artifact.size
        }
        if cancelled() { throw CancellationError() }
        markVerified(model, in: root)
        return true
    }

    /// D86: keep the old install until this exact replacement has passed its checks. Both a successful first load
    /// and a just-published download come through here. Retiring the old id is best effort: it cannot invalidate the
    /// verified replacement, and a later cached check retries it. Readiness or startup pruning alone never retires it.
    private func retireReplacedParakeet(afterVerifying model: ModelDescriptor, in root: URL) {
        guard model == ModelCatalog.parakeet, model.ready(in: root) else { return }
        let old = ModelCatalog.legacyParakeet.directory(in: root).deletingLastPathComponent()
        do {
            try ModelFiles.retire(old)
        } catch {
            ModelInstallDiagnostics.failure(model: ModelCatalog.legacyParakeet.id,
                                            stage: "retire-replaced-model", error: error)
        }
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("ModelVerifier: \(message)")
        #endif
    }
}
