import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

/// The Library's banner buttons (Android `LibraryViewModel.bannerAction`) and the facts the app's sources give them.
@MainActor @Suite struct NoticesStoreTests {
    /// Up to 30 s by the clock (E1): 500 sleeps of 10 ms ran out after 5 s, or less, on a busy host. The test checks
    /// the outcome itself.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A note directory that kept its capture but lost `note.json`, recorded at `createdAt`: the launch rebuilds it.
    private func bareCapture(in test: TestGraph, id: UUID, createdAt: Date) throws {
        let folder = test.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = folder.appendingPathComponent(RecordingController.captureFilename)
        try Data().write(to: capture)
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: capture.path)
    }

    private func recoveredBanner(_ graph: AppGraph) -> BannerSpec? {
        graph.notices.library(LibraryFacts(loading: true)).first { $0.kind == .recovered }
    }

    /// Two recoveries whose folder order is not their recording order.
    private func twoRecovered(in test: TestGraph) throws -> (older: UUID, newer: UUID) {
        let newer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let older = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!
        try bareCapture(in: test, id: newer, createdAt: Date(timeIntervalSince1970: 2_000_000))
        try bareCapture(in: test, id: older, createdAt: Date(timeIntervalSince1970: 1_000_000))
        return (older, newer)
    }

    // ports: LibraryViewModelTest#recoveredBannerOpensTheLatestNoteAndDismisses
    @Test func recoveredBannerOpensTheLatestNoteAndDismisses() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let (_, newer) = try twoRecovered(in: test)
        await test.graph.start()
        let graph = test.graph
        let banner = try #require(recoveredBanner(graph))
        #expect(banner.args.count == 2)
        #expect(graph.noticeCenter.latestRecovered?.noteID == newer, "the last recorded, not the last rebuilt")

        graph.notices.perform(.open, on: banner)
        #expect(graph.router.path == [.note(newer)])
        #expect(graph.settings.recoveredAck != nil)
        #expect(recoveredBanner(graph) == nil, "Open acknowledges the banner")
    }

    @Test func aRecoveredNoteMovedToRecentlyDeletedLeavesTheBanner() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let (older, newer) = try twoRecovered(in: test)
        await test.graph.start()
        let graph = test.graph
        #expect(recoveredBanner(graph)?.args.count == 2)

        #expect(await graph.trash.requestTrash(newer))
        await waitUntil { graph.library.note(newer)?.trashedAt != nil || graph.library.note(newer) == nil }
        let banner = try #require(recoveredBanner(graph))
        #expect(banner.args.count == 1)
        #expect(graph.noticeCenter.latestRecovered?.noteID == older, "Open never targets a note in Recently Deleted")

        #expect(await graph.trash.requestTrash(older))
        await waitUntil { recoveredBanner(graph) == nil }
        #expect(recoveredBanner(graph) == nil)
    }

    // ports: LibraryViewModelTest#queueHeldBannerContinues
    @Test func queueHeldBannerContinues() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1, total: 2)))
        defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var notes: [Note] = []
        for title in ["A", "B"] {
            var note = Note(title: title, audioFilename: "audio.caf")
            note.duration = 2
            try repository.save(note)
            try Data().write(to: repository.audioURL(for: note))
            notes.append(note)
        }
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        graph.settings.queueHold = .user
        await graph.start()
        for note in notes { await graph.processing.transcribe(note.id, origin: .automatic) }

        let banner = try #require(graph.notices.library(LibraryFacts(loading: true)).first { $0.kind == .txQueueHeld })
        #expect(banner.args.count == 2)
        #expect(banner.actions == [.continue])
        graph.notices.perform(.continue, on: banner)
        #expect(graph.settings.queueHold == nil)
        await waitUntil { graph.processing.state.running != nil }
        #expect(graph.processing.state.running != nil, "the queue goes on")
        #expect(!graph.notices.library(LibraryFacts(loading: true)).contains { $0.kind == .txQueueHeld })
        graph.processing.stopAll()
    }

    @Test func aStandaloneInstallWithoutSpaceSaysHowMuchToFree() async throws {
        let test = TestGraph(transcriber: NoSpaceTranscriber())
        defer { test.tearDown() }
        await test.graph.start()
        let graph = test.graph
        graph.processing.models.install([.speech])
        await waitUntil { graph.processing.models.download?.failure != nil }
        let banner = try #require(graph.notices.library(LibraryFacts(loading: true)).first { $0.kind == .dlNoSpace })
        #expect(banner.args.bytes == ModelDownloadPlan.speechInstallBytes)
        #expect(BannerCopy.body(banner, locale: Locale(identifier: "en_US")) == "Free about 512 MB and try again.")
    }

    @Test func theSettingsCancelStopsTheStandaloneInstallAndNotTheJobThatDownloads() async throws {
        let test = TestGraph(transcriber: HangingDownloads())
        defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var note = Note(title: "A", audioFilename: "audio.caf")
        note.duration = 2
        try repository.save(note)
        try Data().write(to: repository.audioURL(for: note))
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        await graph.start()
        await graph.processing.transcribe(note.id, origin: .automatic)
        await waitUntil {
            if case .downloading = graph.processing.state.running?.phase { true } else { false }
        }
        graph.processing.models.install([.speech])
        await waitUntil { graph.notices.settingsBanners.contains { $0.kind == .dlDownloading } }
        let banner = try #require(graph.notices.settingsBanners.first { $0.kind == .dlDownloading })

        graph.notices.perform(.cancel, on: banner)
        #expect(!graph.processing.models.isInstalling, "the install the banner names stops")
        #expect(!graph.notices.settingsBanners.contains { $0.kind == .dlDownloading })
        guard case .downloading = graph.processing.state.running?.phase else {
            Issue.record("the job's download goes on")
            return
        }
        graph.processing.stopAll()
    }
}

/// Apple's speech assets that cannot be installed for want of space.
private struct NoSpaceTranscriber: Transcribing {
    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        throw TranscriptionError.failed(.download(.notEnoughStorage))
    }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .notDownloaded }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        throw TranscriptionError.failed(.download(.notEnoughStorage))
    }
    func speechLanguages() async -> [SpeechLanguage] { [] }
}

/// Apple's speech assets downloading for a job and for a standalone install, neither of which ends until cancelled.
private struct HangingDownloads: Transcribing {
    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        events(.preparingModel(.downloading(0.3)))
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .notDownloaded }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        progress(.downloading(0.2))
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
    func speechLanguages() async -> [SpeechLanguage] { [] }
}
