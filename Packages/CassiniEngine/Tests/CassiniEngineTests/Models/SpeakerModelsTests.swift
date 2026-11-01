import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The speaker models through the catalog (`SpeakerModels`): one row for the diarizer and CAM++, installed by the
/// shared installer with the speaker consent of iOS. The fetcher writes
/// sparse files of the pinned sizes, so nothing is downloaded.
@MainActor @Suite final class SpeakerModelsTests {
    private let folder = TemporaryFolder()
    private let suite = "cassini.tests.\(UUID().uuidString)"
    private let fetcher: SparseFetcher
    private let repository: ModelRepository
    private let models: SpeakerModels

    init() {
        // No speech consent: the speaker models have their own, which their callers check.
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: FakeClock(), defaultLanguage: "en-US")
        fetcher = SparseFetcher()
        repository = ModelRepository(root: folder.root.appendingPathComponent("models"), consent: settings, fetcher: fetcher)
        models = SpeakerModels(repository: repository,
                               installer: PinnedModelInstaller(models: repository, storage: FakeStorage(), online: { true }))
    }

    deinit {
        folder.remove()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func bothModelsInstallAsOneRowWithoutTheSpeechConsent() async throws {
        #expect(await models.refresh(linked: true) == .notDownloaded)
        #expect(models.status(linked: false) == .unsupported, "a build without the native runtime")
        #expect(models.installBytes == ModelPlan(ModelPlan.of(root: models.root).missing
            .filter { $0.part != .speech }).requiredFreeBytes)
        let reports = Mutex<[InstallProgress]>([])
        try await models.install { progress in reports.withLock { $0.append(progress) } }
        #expect(fetcher.fetched == [ModelCatalog.diarization.pin, ModelCatalog.voiceprint.pin],
                "the diarizer, then CAM++, nothing of speech")
        #expect(models.diarizerReady && models.printsReady)
        #expect(await models.refresh(linked: true) == .ready)
        #expect(models.installBytes == 0)
        let fractions = reports.withLock { $0 }.compactMap { if case .downloading(let value?) = $0 { value } else { nil } }
        #expect(fractions == fractions.sorted(), "one rising fraction over both downloads")
        #expect(fractions.last == 1)
        #expect(reports.withLock { $0 }.contains(.checking))
        // Installed: a second install fetches nothing.
        try await models.install { _ in }
        #expect(fetcher.fetched.count == 2)
    }

    @Test func aFailedDiarizerIsTheRowsFailure() async throws {
        fetcher.fails = [ModelCatalog.diarization]
        await #expect(throws: SpeakerAnalysisError.download(.fileCheckFailed, requiredFreeBytes: 0)) {
            try await self.models.install { _ in }
        }
        #expect(!models.diarizerReady)
        #expect(models.status(linked: true) == .failed(.fileCheckFailed))
        fetcher.fails = []
        try await models.install { _ in }
        #expect(models.status(linked: true) == .ready, "the next install clears the failure")
    }

    @Test func aFailedVoiceprintModelLeavesTheDiarizer() async throws {
        fetcher.fails = [ModelCatalog.voiceprint]
        await #expect(throws: SpeakerAnalysisError.download(.fileCheckFailed, requiredFreeBytes: 0)) {
            try await self.models.install { _ in }
        }
        #expect(models.diarizerReady && !models.printsReady, "speakers are told apart, voices are not matched")
        #expect(models.status(linked: true) == .failed(.fileCheckFailed))
    }

    @Test func offlineTheModelsAreNotTriedAndSayNoConnection() async throws {
        let offline = SpeakerModels(repository: repository,
                                    installer: PinnedModelInstaller(models: repository, storage: FakeStorage(), online: { false }))
        await #expect(throws: SpeakerAnalysisError.download(.noConnection, requiredFreeBytes: 0)) {
            try await offline.install { _ in }
        }
        #expect(fetcher.fetched.isEmpty)
    }

    @Test func theCatalogPartsAndDownloadsAreAndroids() {
        #expect(SpeakerModels.parts == [.speakers, .voices])
        let downloads = ModelCatalog.downloads.map(\.url.absoluteString)
        for model in [ModelCatalog.diarizationModel, ModelCatalog.voiceprintModel] {
            #expect(model.download.map { downloads.contains($0.url) } == true, "\(model.name)")
        }
        // The manifest's paths, each model in its own revision directory (D4).
        #expect(models.diarizer.path == ModelCatalog.diarization.path(in: models.root, "model.int8.onnx"))
        #expect(models.voiceprint.path
                == ModelCatalog.voiceprint.path(in: models.root, "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"))
        #expect(models.diarizer.deletingLastPathComponent().lastPathComponent == ModelCatalog.diarization.sourceSha256)
    }
}

/// Writes sparse files of `model`'s pinned sizes, reporting halfway then the whole, then the check; a model in `fails`
/// fails its check.
final class SparseFetcher: ModelFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetched: [String] = []
    private var _fails: Set<ModelDescriptor> = []

    var fetched: [String] { lock.withLock { _fetched } }
    var fails: Set<ModelDescriptor> {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    func fetch(_ model: ModelDescriptor, into directory: URL, progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        lock.withLock { _fetched.append(model.pin) }
        progress(model.downloadBytes / 2, false)
        progress(model.downloadBytes, false)
        progress(model.downloadBytes, true)
        if fails.contains(model) { throw ModelError(.modelVerify) }
        sparse(model, in: directory)
    }
}

/// `work/clips.pcm`: what it keeps across runs and what it reads back.
@Suite struct ClipFileTests {
    private let folder = TemporaryFolder()

    @Test func aResumedRunCutsTheFileBackToTheCheckpoint() throws {
        defer { folder.remove() }
        let url = folder.root.appendingPathComponent("work/clips.pcm")
        let clips = try ClipFile(url: url, keeping: nil)
        try clips.append([0.5, -0.25, 1, 2][...])
        try clips.sync()
        #expect(clips.sampleCount == 4)
        #expect(try clips.read(1, 2) == [-0.25, 1])
        // A process that died after appending more than its checkpoint counted.
        let resumed = try ClipFile(url: url, keeping: 3)
        #expect(resumed.sampleCount == 3)
        #expect(try resumed.read(0, 3) == [0.5, -0.25, 1])
        #expect(length(url) == 12)
        #expect(throws: (any Error).self) { try ClipFile(url: url, keeping: 4) }
        // A fresh run starts empty.
        #expect(try ClipFile(url: url, keeping: nil).sampleCount == 0)
        #expect(length(url) == 0)
    }

    @Test func theClipsLiveInTheNotesWorkFolderOnly() throws {
        defer { folder.remove() }
        let gone = folder.root.appendingPathComponent("deleted-note/work/clips.pcm")
        #expect(throws: (any Error).self) { try ClipFile(url: gone, keeping: nil) }
        #expect(!exists(folder.root.appendingPathComponent("deleted-note")), "no folder without its note")
        let files = CheckpointFiles(noteDirectory: { _ in self.folder.root })
        #expect(files.clipsURL(for: UUID())?.path.hasSuffix("/work/clips.pcm") == true)
    }
}
