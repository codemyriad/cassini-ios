import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Android's ModelRepositoryTest over a scratch model root: statuses from fake marker files, consent in a real
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

    private func repository(failing: [ModelDescriptor: JobFailure] = [:]) -> ModelRepository {
        ModelRepository(root: models, consent: settings, fetcher: FakeFetcher(failing: failing, log: log))
    }

    /// Writes each artifact as a sparse file and reports download and check progress, or fails for `failing`.
    private struct FakeFetcher: ModelFetching {
        let failing: [ModelDescriptor: JobFailure]
        let log: FetchLog

        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
            log.append("\(model.directory)/\(model.markerFile)")
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
        #expect(repo.plan().totalMebibytes == 730)
    }

    // ports: ModelRepositoryTest#markerFilesDecideReadiness
    @Test func markerFilesDecideReadiness() async throws {
        install(ModelCatalog.parakeet, in: models)
        install(ModelCatalog.diarization, in: models, marker: "another sha")
        install(ModelCatalog.voiceprint, in: models)
        // A file of the wrong size is not ready, even with the right marker.
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
        #expect(!ModelCatalog.voiceprint.ready(in: models), "the voiceprint marker is separate")
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
        #expect(!exists(ModelCatalog.voiceprint.directory(in: models).appendingPathComponent("verified-voiceprint")))
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
        #expect(log.entries == ["parakeet-ultra/verified"], "no detector after a cancelled Parakeet")
    }

    // ports: ModelRepositoryTest#anInstallSkipsReadyModelsAndKeepsMarkersUntilVerified
    @Test func anInstallSkipsReadyModelsAndKeepsMarkersUntilVerified() async throws {
        install(ModelCatalog.parakeet, in: models)
        let repo = repository()
        await repo.refresh()

        _ = try await repo.install(.speech)

        #expect(log.entries == ["vad/verified"])
        #expect(ModelCatalog.vad.ready(in: models))
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

    /// iOS only: the models download again, so they stay out of backups.
    @Test func theModelsAreExcludedFromBackups() async throws {
        let repo = repository()
        _ = try await repo.install(.voices)
        #expect(try models.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}

/// The models a fake fetcher was asked for, in order.
private final class FetchLog: Sendable {
    private let items = Mutex<[String]>([])
    func append(_ item: String) { items.withLock { $0.append(item) } }
    var entries: [String] { items.withLock { $0 } }
}
