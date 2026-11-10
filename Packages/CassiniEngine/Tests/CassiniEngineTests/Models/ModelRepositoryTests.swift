import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Android's ModelRepositoryTest over a scratch model root: statuses from fake revision directories, consent in a real
/// `SettingsStore`, and installs through a fake fetcher. No real model file is read or written.
@MainActor @Suite final class ModelRepositoryTests {
    private let folder = TemporaryFolder()
    private let suite = "cassini.tests.\(UUID().uuidString)"
    private let clock = FakeClock(now: Date(timeIntervalSince1970: 42))
    private lazy var settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, defaultLanguage: "en-US")
    private let log = FetchLog()
    private var models: URL { folder.root.appendingPathComponent("models", isDirectory: true) }

    deinit {
        folder.remove()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private let verifier = ModelVerifier { _, _, _ in "" }

    private func repository(failing: [ModelDescriptor: JobFailure] = [:]) -> ModelRepository {
        ModelRepository(root: models, consent: settings, fetcher: FakeFetcher(failing: failing, log: log),
                        verifier: verifier)
    }

    /// Writes each artifact as a sparse file and reports download and check progress, or fails for `failing`.
    private struct FakeFetcher: ModelFetching {
        let failing: [ModelDescriptor: JobFailure]
        let log: FetchLog

        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
            log.append(model.pin)
            log.directories.withLock { $0.append(directory) }
            if let failure = failing[model] { throw ModelError(failure) }
            progress(model.downloadBytes / 2, false)
            progress(model.downloadBytes, false)
            progress(model.downloadBytes / 2, true)
            sparse(model, in: directory)
        }
    }

    private var everyPart: [ModelPart: ModelStatus] {
        ModelPart.allCases.reduce(into: [:]) { $0[$1] = .missing(consented: false) }
    }

    // ports: ModelRepositoryTest#nothingInstalledAndNoConsent
    @Test func nothingInstalledAndNoConsent() async {
        let repo = repository()
        #expect(repo.status.isEmpty, "unknown until the first refresh")

        let status = await repo.refresh()

        #expect(status == everyPart)
        #expect(repo.status == status)
        #expect(await !repo.consented())
        #expect(repo.plan().parts == ModelPart.allCases)
        #expect(repo.plan().totalMebibytes == 528)
    }

    // ports: ModelRepositoryTest#markerFilesDecideReadiness (iOS: the revision directories, with their notices)
    @Test func markerFilesDecideReadiness() async throws {
        install(ModelCatalog.parakeet, in: models)
        install(ModelCatalog.diarization, in: models)
        try FileManager.default.removeItem(at: ModelCatalog.diarization.directory(in: models)
            .appendingPathComponent(ModelDescriptor.noticeFile))
        install(ModelCatalog.voiceprint, in: models)
        // A file of the wrong size is not ready, even with the notices.
        sparse(ModelCatalog.voiceprint.directory(in: models).appendingPathComponent(ModelCatalog.voiceprintModel.name), size: 10)

        let status = await repository().refresh()

        #expect(status[.speech] == .ready)
        // Parakeet installed counts as consent.
        #expect(status[.speakers] == .missing(consented: true))
        #expect(status[.voices] == .missing(consented: true))
        #expect(await repository().consented())
        #expect(repository().plan().parts == [.speakers, .voices])
        #expect(repository().ready(.speech), "the speech detector is best effort")
    }

    // ports: ModelRepositoryTest#consentIsTheStoredTimeOrParakeet
    /// A consent recorded for Apple's speech assets is the same `models.consentAt`, so it still counts.
    @Test func consentIsTheStoredTimeOrParakeet() async {
        let repo = repository()
        await repo.refresh()
        await repo.recordDeclined()
        #expect(await !repo.consented())

        await repo.recordConsent()

        #expect(await repo.consented())
        #expect(settings.modelsConsentAt == Date(timeIntervalSince1970: 42))
        #expect(settings.modelsDeclinedAt == Date(timeIntervalSince1970: 42))
        #expect(repo.status[.speech] == .missing(consented: true))
    }

    // ports: ModelRepositoryTest#anInstallReportsProgressAndEndsReady
    @Test func anInstallReportsProgressAndEndsReady() async throws {
        let repo = repository()
        await repo.refresh()
        let seen = Mutex<[ModelStatus]>([])

        let result = try await repo.install(.speakers) { status in seen.withLock { $0.append(status) } }

        #expect(result.skipped.isEmpty)
        #expect(repo.status[.speakers] == .ready)
        #expect(repo.status[.voices] == .missing(consented: false))
        let total = ModelCatalog.diarization.downloadBytes
        let events = seen.withLock { $0 }
        #expect(events.first == .downloading(percent: 50, bytes: total / 2, total: total))
        #expect(events.dropFirst().first == .downloading(percent: 100, bytes: total, total: total))
        #expect(events.dropFirst(2).first == .verifying(percent: 50))
        #expect(events.last == .ready)
        #expect(ModelCatalog.diarization.ready(in: models))
        #expect(!ModelCatalog.voiceprint.ready(in: models), "the voiceprint has its own directory")
        #expect(verifier.isChecked(ModelCatalog.diarization, in: models), "an install has just checked every file")
    }

    // ports: ModelRepositoryTest#aFailedExtraIsSkippedAndAFailedPrimaryFailsThePart
    @Test func aFailedExtraIsSkippedAndAFailedPrimaryFailsThePart() async throws {
        let repo = repository(failing: [ModelCatalog.vad: .modelDownload])
        await repo.refresh()

        let speech = try await repo.install(.speech)

        #expect(speech.skipped == [ModelCatalog.vad])
        #expect(repo.status[.speech] == .ready)
        #expect(!ModelCatalog.vad.ready(in: models))

        let failing = repository(failing: [ModelCatalog.voiceprint: .modelVerify])
        await failing.refresh()
        await #expect(throws: ModelError(.modelVerify)) { try await failing.install(.voices) }
        #expect(failing.status[.voices] == .failed(.modelVerify, detail: "VERIFY"))
        #expect(!exists(ModelCatalog.voiceprint.directory(in: models)), "no revision without every file checked")
        // The failure stays until the part is installed.
        #expect(await failing.refresh()[.voices] == .failed(.modelVerify, detail: "VERIFY"))
        install(ModelCatalog.voiceprint, in: models)
        #expect(await failing.refresh()[.voices] == .ready)
    }

    // ports: ModelRepositoryTest#aCancelledInstallShowsTheReadinessAgain
    @Test func aCancelledInstallShowsTheReadinessAgain() async {
        let repo = repository(failing: [ModelCatalog.parakeet: .cancelled])
        await repo.refresh()

        _ = try? await repo.install(.speech)

        #expect(repo.status[.speech] == .missing(consented: false))
        #expect(log.entries == [ModelCatalog.parakeet.pin], "no detector after a cancelled Parakeet")
    }

    // ports: ModelRepositoryTest#anInstallSkipsReadyModelsAndKeepsMarkersUntilVerified (iOS: the files go to the
    // staging directory, and only a complete one becomes the revision)
    @Test func anInstallSkipsReadyModelsAndKeepsMarkersUntilVerified() async throws {
        install(ModelCatalog.parakeet, in: models)
        let repo = repository()
        await repo.refresh()

        _ = try await repo.install(.speech)

        #expect(log.entries == [ModelCatalog.vad.pin])
        #expect(log.directories.withLock { $0 } == [ModelCatalog.vad.staging(in: models)])
        #expect(ModelCatalog.vad.ready(in: models))
        #expect(!exists(ModelCatalog.vad.staging(in: models)), "renamed into place")
    }

    /// An install that fails or is stopped publishes no revision; its staging directory keeps the parts and the checked
    /// files, and the next install fetches into the same one.
    @Test func anInterruptedInstallLeavesNoRevisionAndResumesFromItsStaging() async throws {
        struct Halfway: ModelFetching {
            func fetch(_ model: ModelDescriptor, into directory: URL,
                       progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
                sparse(directory.appendingPathComponent("\(model.artifacts[0].sha256).part"), size: 10)
                throw ModelError(.modelDownload, "dropped")
            }
        }
        let model = ModelCatalog.voiceprint
        let halfway = ModelRepository(root: models, consent: settings, fetcher: Halfway(), verifier: verifier)
        await #expect(throws: ModelError(.modelDownload, "dropped")) { try await halfway.installModel(model) { _, _ in } }
        #expect(!exists(model.directory(in: models)))
        #expect(length(model.staging(in: models).appendingPathComponent("\(model.artifacts[0].sha256).part")) == 10)

        try await repository().installModel(model) { _, _ in }

        #expect(log.directories.withLock { $0 } == [model.staging(in: models)])
        #expect(model.ready(in: models))
        #expect(try FileManager.default.contentsOfDirectory(atPath: model.directory(in: models).path).sorted()
                == [model.artifacts[0].name, ModelDescriptor.noticeFile].sorted(), "no part is kept in the revision")
    }

    /// A fetch that leaves a file or the notices out publishes nothing.
    @Test func anIncompleteFetchPublishesNothing() async throws {
        struct NoNotice: ModelFetching {
            func fetch(_ model: ModelDescriptor, into directory: URL,
                       progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
                sparse(model, in: directory)
                try FileManager.default.removeItem(at: directory.appendingPathComponent(ModelDescriptor.noticeFile))
            }
        }
        let repo = ModelRepository(root: models, consent: settings, fetcher: NoNotice(), verifier: verifier)
        let error = await #expect(throws: ModelError.self) { try await repo.installModel(ModelCatalog.vad) { _, _ in } }
        #expect(error?.failure == .modelInstall)
        #expect(!ModelCatalog.vad.ready(in: models))
        #expect(!verifier.isChecked(ModelCatalog.vad, in: models))
    }

    /// A revision directory that is there but not complete (a file cut short) is retired before the new one is
    /// published: renamed away and deleted, never mixed with the new files.
    @Test func aBrokenRevisionIsRetiredBeforeTheNewOneIsPublished() async throws {
        let model = ModelCatalog.diarization
        install(model, in: models)
        let stale = model.directory(in: models).appendingPathComponent("stale.bin")
        try Data("old".utf8).write(to: stale)
        sparse(model.directory(in: models).appendingPathComponent(model.artifacts[0].name), size: 10)
        #expect(!model.ready(in: models))

        try await repository().installModel(model) { _, _ in }

        #expect(model.ready(in: models))
        #expect(!exists(stale))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: model.directory(in: models)
            .deletingLastPathComponent().path)
        #expect(siblings == [model.sourceSha256], "no .remove- directory is left")
    }

    /// D51: nothing of earlier development builds is migrated. Their directories, other revisions of a model, ids the
    /// catalog does not have and retired revisions are deleted; each pinned revision and its staging directory stay.
    @Test func revisionsOutsideTheCatalogAreRemoved() throws {
        for model in ModelCatalog.all { install(model, in: models) }
        let manager = FileManager.default
        let staging = ModelCatalog.parakeet.staging(in: models)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        sparse(staging.appendingPathComponent("caf7.part"), size: 10)
        let gone = [
            models.appendingPathComponent("parakeet-ultra"), models.appendingPathComponent("vad"),
            models.appendingPathComponent("speaker-models"), models.appendingPathComponent("stray.txt"),
            models.appendingPathComponent("models/whistle"),
            models.appendingPathComponent("models/silero-vad/\(String(repeating: "0", count: 64))"),
            models.appendingPathComponent("models/silero-vad/.\(String(repeating: "0", count: 64)).staging"),
            models.appendingPathComponent("models/nemotron-3-diarization-int8/.remove-\(UUID().uuidString)"),
        ]
        for url in gone { try manager.createDirectory(at: url, withIntermediateDirectories: true) }

        repository().prune()

        for url in gone { #expect(!exists(url), "\(url.lastPathComponent)") }
        for model in ModelCatalog.all { #expect(model.ready(in: models), "\(model.pin)") }
        #expect(length(staging.appendingPathComponent("caf7.part")) == 10)
        ModelRepository.prune(root: folder.root.appendingPathComponent("nothing"))
    }

    // ports: ModelRepositoryTest#theInstallOwnerPushesProgress
    @Test func theInstallOwnerPushesProgress() async {
        let repo = repository()
        await repo.refresh()

        repo.publishProgress(.speech, .downloading(percent: 46, bytes: 46, total: 100))
        #expect(repo.status[.speech] == .downloading(percent: 46, bytes: 46, total: 100))
        repo.publishProgress(.speech, .verifying(percent: 80))
        #expect(repo.status[.speech] == .verifying(percent: 80))
        repo.clearProgress(.speech)
        #expect(repo.status[.speech] == .missing(consented: false))
        #expect(!repo.publishProgress(.speech, .ready), "a readiness is no progress")
    }

    /// iOS only: a write that finds the disk full is NOT_ENOUGH_STORAGE (iOS reports it as its own error), not a
    /// failed download.
    @Test func aFullDiskDuringADownloadIsNotEnoughStorage() async throws {
        struct FullDisk: ModelFetching {
            func fetch(_ model: ModelDescriptor, into directory: URL,
                       progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        let repo = ModelRepository(root: models, consent: settings, fetcher: FullDisk())
        let error = await #expect(throws: ModelError.self) {
            try await repo.installModel(ModelCatalog.voiceprint) { _, _ in }
        }
        #expect(error?.failure == .space)
        let store = RepositoryModelStore(models: repo, storage: FakeStorage(), online: { true }, consented: true)
        let speech = ModelPlan([ModelPlan.of(root: models).missing[0]])

        let outcome = try await ModelInstaller(store: store).install([.speech]) { _ in } { _ in }

        #expect(outcome == .failed(part: .speech, error: .notEnoughStorage, requiredFreeBytes: speech.requiredFreeBytes))
    }

    @Test(arguments: [CocoaError(.fileReadNoPermission) as NSError,
                      CocoaError(.fileWriteUnknown) as NSError,
                      POSIXError(.EACCES) as NSError])
    func localFileFailuresAreInstallFailuresRatherThanNetworkFailures(_ error: NSError) async throws {
        struct FailingFiles: ModelFetching {
            let error: NSError
            func fetch(_ model: ModelDescriptor, into directory: URL,
                       progress: @escaping @Sendable (Int64, Bool) -> Void) async throws { throw error }
        }
        let repo = ModelRepository(root: models, consent: settings, fetcher: FailingFiles(error: error))
        let failure = await #expect(throws: ModelError.self) {
            try await repo.installModel(ModelCatalog.voiceprint) { _, _ in }
        }
        #expect(failure?.failure == .modelInstall)
        #expect(!ModelCatalog.voiceprint.ready(in: models))
    }

    @Test func cancellationAfterTheFetchCannotPublishARevision() async throws {
        struct CancelAtCompletion: ModelFetching {
            func fetch(_ model: ModelDescriptor, into directory: URL,
                       progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
                sparse(model, in: directory)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let repo = ModelRepository(root: models, consent: settings, fetcher: CancelAtCompletion())
        let result = await Task.detached {
            await failure { try await repo.installModel(ModelCatalog.voiceprint) { _, _ in } }
        }.value
        #expect(result == .cancelled)
        #expect(!ModelCatalog.voiceprint.ready(in: models))
        #expect(ModelCatalog.voiceprint.complete(ModelCatalog.voiceprint.staging(in: models)),
                "Cancellation preserves the checked staging files for a later attempt")
    }

    @Test func aMetadataTimeoutRemainsADownloadFailure() async throws {
        struct TimedOut: ModelFetching {
            func fetch(_ model: ModelDescriptor, into directory: URL,
                       progress: @escaping @Sendable (Int64, Bool) -> Void) async throws { throw URLError(.timedOut) }
        }
        let repo = ModelRepository(root: models, consent: settings, fetcher: TimedOut())
        let failure = await #expect(throws: ModelError.self) {
            try await repo.installModel(ModelCatalog.voiceprint) { _, _ in }
        }
        #expect(failure?.failure == .modelDownload)
        #expect(failure?.urlErrorCode == .timedOut)
    }

    @Test func aRootThatCannotBePreparedFailsBeforeAnyDownload() async throws {
        try Data("occupied".utf8).write(to: models)
        let failure = await #expect(throws: ModelError.self) {
            try await repository().installModel(ModelCatalog.voiceprint) { _, _ in }
        }
        #expect(failure?.failure == .modelInstall)
        #expect(log.entries.isEmpty)
    }

    /// iOS only: the models download again, so they stay out of backups.
    @Test func theModelsAreExcludedFromBackups() async throws {
        let repo = repository()
        _ = try await repo.install(.voices)
        #expect(try models.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}

/// The models a fake fetcher was asked for, in order, and the directories it filled.
private final class FetchLog: Sendable {
    private let items = Mutex<[String]>([])
    let directories = Mutex<[URL]>([])
    func append(_ item: String) { items.withLock { $0.append(item) } }
    var entries: [String] { items.withLock { $0 } }
}

extension ModelRepositoryTests {
    private struct TransportOrLocalFailure: ModelFetching {
        let error: any Error
        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws { throw error }
    }

    private func installFailure(_ error: any Error, expected: DownloadError, online: Bool = true) async throws {
        let repo = ModelRepository(root: models, consent: settings, fetcher: TransportOrLocalFailure(error: error))
        let store = RepositoryModelStore(models: repo, storage: FakeStorage(), online: { online }, consented: true)
        let outcome = try await ModelInstaller(store: store).install([.speech]) { _ in }
        guard case .failed(let part, let mapped, _) = outcome else {
            Issue.record("Expected a required speech install failure"); return
        }
        #expect(part == .speech)
        #expect(mapped == expected)
        // The shared owner builds its own RepositoryModelStore; cover the production path, not only downloadError.
        let owner = PinnedModelInstaller(models: repo, storage: FakeStorage(), online: { online })
        let shared = try await owner.install([.speech], granted: true)
        guard case .failed(let sharedPart, let sharedError, _) = shared else {
            Issue.record("Expected a shared required speech install failure"); return
        }
        #expect(sharedPart == .speech)
        #expect(sharedError == expected)
        try await waitUntil { owner.status == .idle }
    }

    @Test func transportFailuresThroughTheRepositoryStayNoConnectionOnValidatedWifi() async throws {
        let codes: [URLError.Code] = [.timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                                     .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff]
        for code in codes {
            try await installFailure(URLError(code), expected: .noConnection)
        }
        // NSError bridging at the URLSession boundary must retain the same typed transport identity.
        try await installFailure(NSError(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue), expected: .noConnection)
    }

    @Test func aLostConnectionKeepsItsInterruptedVersusOfflineMeaningThroughTheRepository() async throws {
        try await installFailure(URLError(.networkConnectionLost), expected: .interrupted)
        try await installFailure(URLError(.networkConnectionLost), expected: .noConnection, online: false)
    }

    @Test func localFileFailuresThroughTheRepositoryAreNotMisreportedAsConnectivity() async throws {
        try await installFailure(CocoaError(.fileReadNoPermission), expected: .install)
        try await installFailure(CocoaError(.fileWriteNoPermission), expected: .install)
        try await installFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)), expected: .install)
        try await installFailure(CocoaError(.fileWriteOutOfSpace), expected: .notEnoughStorage)
    }

    @Test func transportCancellationThroughTheRepositoryAndSharedOwnerStaysCancellation() async throws {
        let errors: [any Error] = [URLError(.cancelled), ModelError(.modelDownload, urlErrorCode: .cancelled)]
        for error in errors {
            let repo = ModelRepository(root: models, consent: settings, fetcher: TransportOrLocalFailure(error: error))
            do {
                _ = try await repo.install(.speech)
                Issue.record("Cancelled repository install must not succeed")
            } catch { #expect(ModelInstaller.isCancellation(error)) }
            if case .failed? = repo.status[.speech] { Issue.record("Cancellation must not leave a failed model status") }
            let store = RepositoryModelStore(models: repo, storage: FakeStorage(), online: { true }, consented: true)
            await #expect(throws: CancellationError.self) { try await ModelInstaller(store: store).install([.speech]) { _ in } }
            let owner = PinnedModelInstaller(models: repo, storage: FakeStorage(), online: { true })
            await #expect(throws: CancellationError.self) { try await owner.install([.speech], granted: true) }
            try await waitUntil { owner.status == .idle }
        }
    }
}
