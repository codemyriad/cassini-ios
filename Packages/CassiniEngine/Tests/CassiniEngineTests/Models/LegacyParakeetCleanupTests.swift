import Foundation
import Synchronization
import Testing
@testable import CassiniEngine

/// D86: metadata is not verification. Old weights survive every unsuccessful replacement path; successful
/// publication and a successful first load both retire them. Sparse files avoid allocating model-sized buffers.
@Suite struct LegacyParakeetCleanupTests {
    enum ReplacementState: CaseIterable, Equatable, Sendable { case missing, incomplete, unchecked }
    enum FetchEnd: CaseIterable, Sendable { case downloadFailure, verifyFailure, cancelled, incomplete, cancelAfterFetch }

    private var current: ModelDescriptor { ModelCatalog.parakeet }
    private var legacy: ModelDescriptor { ModelCatalog.legacyParakeet }

    private func expectedDigest(_ file: URL) -> String {
        ModelCatalog.all.flatMap(\.artifacts).first { $0.name == file.lastPathComponent }?.sha256 ?? "not a pinned artifact"
    }

    private func verifier(count: Counter = Counter()) -> ModelVerifier {
        ModelVerifier { file, _, _ in
            _ = count.next()
            return expectedDigest(file)
        }
    }

    @Test(arguments: ReplacementState.allCases)
    func pruningKeepsTheOldInstallUntilTheReplacementVerifies(_ state: ReplacementState) throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root)
        switch state {
        case .missing: break
        case .incomplete:
            let staging = current.staging(in: folder.root)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            sparse(staging.appendingPathComponent("encoder.part"), size: 7)
        case .unchecked: install(current, in: folder.root)
        }

        ModelRepository.prune(root: folder.root)

        #expect(legacy.ready(in: folder.root))
        #expect(current.ready(in: folder.root) == (state == .unchecked))
        if state == .incomplete { #expect(length(current.staging(in: folder.root).appendingPathComponent("encoder.part")) == 7) }
    }

    @Test func successfulFirstVerificationRetiresTheWholeOldIdAndKeepsTheNewInstall() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root); install(current, in: folder.root)
        let oldId = legacy.directory(in: folder.root).deletingLastPathComponent()
        let stale = oldId.appendingPathComponent("other-revision")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let count = Counter(), checked = verifier(count: count)

        #expect(try checked.verify(current, in: folder.root))

        #expect(count.value == current.artifacts.count)
        #expect(checked.isChecked(current, in: folder.root))
        #expect(current.ready(in: folder.root))
        #expect(!exists(oldId), "the old install and its obsolete revisions are retired together")
        let models = folder.root.appendingPathComponent(ModelDescriptor.modelsDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == [current.id],
                "retirement leaves no .remove directory")
    }

    @Test func aCachedVerificationRetriesCleanupWithoutHashingAgain() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(current, in: folder.root)
        let count = Counter(), checked = verifier(count: count)
        #expect(try checked.verify(current, in: folder.root))
        // Stand in for old files remaining after an earlier best-effort cleanup failed.
        install(legacy, in: folder.root)

        #expect(try checked.verify(current, in: folder.root))
        #expect(try checked.verify(current, in: folder.root), "cleanup is idempotent")

        #expect(count.value == current.artifacts.count)
        #expect(!exists(legacy.directory(in: folder.root).deletingLastPathComponent()))
        #expect(current.ready(in: folder.root))
    }

    @Test func aBadReplacementHashKeepsTheOldInstall() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root); install(current, in: folder.root)
        let checked = ModelVerifier { _, _, _ in "wrong hash" }

        #expect(try !checked.verify(current, in: folder.root))

        #expect(legacy.ready(in: folder.root))
        #expect(!current.ready(in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root))
    }

    @Test func aMissingReplacementCannotPoisonTheVerificationCache() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root)
        let checked = ModelVerifier { _, _, _ in "wrong hash" }
        checked.markVerified(current, in: folder.root)
        #expect(!checked.isChecked(current, in: folder.root))
        #expect(try !checked.verify(current, in: folder.root))
        #expect(legacy.ready(in: folder.root))

        install(current, in: folder.root)
        #expect(try !checked.verify(current, in: folder.root), "newly appeared files still need their hashes checked")
        #expect(legacy.ready(in: folder.root))
    }

    @Test func anUnreadableReplacementKeepsBothInstalls() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root); install(current, in: folder.root)
        let checked = ModelVerifier { _, _, _ in throw POSIXError(.EIO) }

        #expect(throws: POSIXError.self) { try checked.verify(current, in: folder.root) }

        #expect(legacy.ready(in: folder.root))
        #expect(current.ready(in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root))
    }

    @Test func cancellationDuringTheLastHashKeepsTheOldInstall() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root); install(current, in: folder.root)
        let stop = Mutex(false)
        let last = try #require(current.artifacts.last).name
        let checked = ModelVerifier { file, _, _ in
            if file.lastPathComponent == last { stop.withLock { $0 = true } }
            return expectedDigest(file)
        }

        #expect(throws: CancellationError.self) {
            try checked.verify(current, in: folder.root, cancelled: { stop.withLock { $0 } })
        }

        #expect(legacy.ready(in: folder.root))
        #expect(current.ready(in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root))
    }

    @Test func aCancelledCachedCheckDoesNotRetireTheOldInstall() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(current, in: folder.root)
        let checked = verifier()
        #expect(try checked.verify(current, in: folder.root))
        install(legacy, in: folder.root)

        #expect(throws: CancellationError.self) {
            try checked.verify(current, in: folder.root, cancelled: { true })
        }

        #expect(legacy.ready(in: folder.root))
        #expect(current.ready(in: folder.root))
    }

    @Test func anotherModelOrAnotherRootCannotRetireThisOldInstall() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let other = folder.newFolder("other-root")
        install(legacy, in: folder.root); install(ModelCatalog.vad, in: folder.root)
        let checked = verifier()
        #expect(try checked.verify(ModelCatalog.vad, in: folder.root))
        install(current, in: other)
        #expect(try checked.verify(current, in: other))

        #expect(legacy.ready(in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root))
    }

    @Test func standardizedDotPathsShareTheSameVerificationCache() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let root = folder.newFolder("actual"), dotRoot = root.appendingPathComponent(".", isDirectory: true)
        install(current, in: root)
        let count = Counter(), checked = verifier(count: count)
        #expect(try checked.verify(current, in: root))
        install(legacy, in: root)

        #expect(checked.isChecked(current, in: dotRoot))
        #expect(try checked.verify(current, in: dotRoot))

        #expect(count.value == current.artifacts.count, "the equivalent dot path does not cause another hash")
        #expect(!legacy.ready(in: root))
    }

    @Test func aDifferentArtifactSnapshotWithTheSamePinCannotAuthorizeCleanup() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root); install(current, in: folder.root)
        let other = ModelDescriptor(current.id, current.sourceSha256,
                                    [Artifact("different.bin", 1, String(repeating: "0", count: 64))])
        install(other, in: folder.root)
        let checked = ModelVerifier { _, _, _ in "wrong hash" }
        checked.markVerified(other, in: folder.root)

        #expect(checked.isChecked(other, in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root), "the cache includes the complete artifact snapshot")
        #expect(legacy.ready(in: folder.root))
        #expect(try !checked.verify(current, in: folder.root))
        #expect(legacy.ready(in: folder.root))
    }

    @Test func aRemovedVerifiedReplacementCannotAuthorizeCleanup() throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(current, in: folder.root)
        let checked = verifier()
        #expect(try checked.verify(current, in: folder.root))
        install(legacy, in: folder.root)
        try FileManager.default.removeItem(at: current.directory(in: folder.root))

        #expect(try !checked.verify(current, in: folder.root))

        #expect(legacy.ready(in: folder.root))
    }

    @Test func aPublishedDownloadRetiresTheOldInstallAndMarksTheNewOneVerified() async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root)
        let checked = verifier()
        let repository = ModelRepository(root: folder.root, consent: Consent(), fetcher: SuccessfulFetch(), verifier: checked)

        try await repository.installModel(current) { _, _ in }

        #expect(current.ready(in: folder.root))
        #expect(checked.isChecked(current, in: folder.root))
        #expect(!exists(legacy.directory(in: folder.root).deletingLastPathComponent()))
        #expect(!exists(current.staging(in: folder.root)))
    }

    @Test func anAlreadyReadyButUncheckedInstallDoesNotRetireOldFiles() async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root); install(current, in: folder.root)
        let checked = verifier()
        let repository = ModelRepository(root: folder.root, consent: Consent(), fetcher: SuccessfulFetch(), verifier: checked)

        try await repository.installModel(current) { _, _ in }

        #expect(legacy.ready(in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root))
        #expect(try checked.verify(current, in: folder.root))
        #expect(!legacy.ready(in: folder.root))
    }

    @Test(arguments: FetchEnd.allCases)
    func aFailedOrCancelledDownloadKeepsTheOldInstall(_ end: FetchEnd) async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        install(legacy, in: folder.root)
        let checked = verifier()
        let repository = ModelRepository(root: folder.root, consent: Consent(), fetcher: FailedFetch(end: end), verifier: checked)
        let model = current
        let failed = await Task.detached {
            do {
                try await repository.installModel(model) { _, _ in }
                return false
            } catch { return true }
        }.value

        #expect(failed)
        #expect(legacy.ready(in: folder.root))
        #expect(!current.ready(in: folder.root))
        #expect(!checked.isChecked(current, in: folder.root))
    }

    private struct Consent: ModelConsentRecords {
        func consentAt() async -> Date? { Date(timeIntervalSince1970: 0) }
        func recordConsent() async {}
        func recordDeclined() async {}
    }

    private struct SuccessfulFetch: ModelFetching {
        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
            sparse(model, in: directory)
        }
    }

    private struct FailedFetch: ModelFetching {
        let end: FetchEnd
        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
            switch end {
            case .downloadFailure: throw ModelError(.modelDownload)
            case .verifyFailure: throw ModelError(.modelVerify)
            case .cancelled: throw CancellationError()
            case .incomplete: return
            case .cancelAfterFetch:
                sparse(model, in: directory)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
}
