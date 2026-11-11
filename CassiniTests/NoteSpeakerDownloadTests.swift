import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class NoteSpeakerDownloadTests: XCTestCase {
    func testDeclinedSpeakerModelsStillOfferDownloadAfterRealTranscription() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.returns([
            .init(text: "Hello.", start: 0, end: 1)], total: 2), recognizer: .parakeet),
            analyzer: FakeAnalyzer(modelIdentity: nil))
        defer { test.tearDown() }
        let note = try await transcribeDecliningSpeakerModels(test)
        XCTAssertNil(note.speakerAnalysisFailure, "Declined consent is not an analysis failure")
        XCTAssertTrue((note.speakers ?? []).isOneVoice)
        XCTAssertEqual(note.text, "Hello.")
        XCTAssertNil(test.graph.processing.state.jobs[note.id])
        _ = try downloadKind(note, job: nil)
    }

    func testBackAndNotNowKeepSpeakerDownloadResumableAfterRelaunch() async throws {
        for notNow in [false, true] {
            let test = TestGraph(transcriber: FakeTranscriber(.returns([
                .init(text: "Hello.", start: 0, end: 1)], total: 2), recognizer: .parakeet),
                analyzer: FakeAnalyzer(modelIdentity: nil))
            defer { test.tearDown() }
            let note = try await transcribeDecliningSpeakerModels(test)
            let kind = try downloadKind(note, job: nil)
            let firstOutcome = await test.graph.processing.transcribe(note.id, kind: kind)
            XCTAssertEqual(firstOutcome, .needsConsent)
            let model = ModelDownloadModel(noteID: note.id, ports: try XCTUnwrap(test.graph.processing.modelDownload))
            await model.load()
            var closed = false
            model.onEffect = { if $0 == .close { closed = true } }
            if notNow { model.notNow() } else { model.close() } // Back dismisses without changing the job.
            XCTAssertTrue(closed, "Consent dismissal event completed")
            let waiting = try XCTUnwrap(test.graph.processing.state.jobs[note.id])
            XCTAssertEqual(waiting.state, .needsConsent)
            XCTAssertEqual(waiting.kind, .speakersOnly)
            _ = try downloadKind(note, job: waiting)

            // A fresh composition reloads only persisted files/preferences. Its speech decoder fails if invoked.
            let analyzer = FakeAnalyzer(modelIdentity: nil)
            let reopened = TestGraph(root: test.root, suite: test.suite, clock: test.clock,
                transcriber: FakeTranscriber(.fails(.failed(.unknown)), status: .notDownloaded, recognizer: .parakeet),
                analyzer: analyzer)
            await reopened.graph.start()
            let restored = try XCTUnwrap(reopened.graph.library.note(note.id))
            XCTAssertEqual(restored.transcript, note.transcript)
            let persistedJob = try XCTUnwrap(reopened.graph.processing.state.jobs[note.id])
            XCTAssertEqual(persistedJob.state, .needsConsent)
            XCTAssertEqual(persistedJob.kind, .speakersOnly)
            let retryKind = try downloadKind(restored, job: persistedJob)
            let retry = await reopened.graph.processing.transcribe(note.id, kind: retryKind)
            XCTAssertEqual(retry, .needsConsent)
            let resumed = ModelDownloadModel(noteID: note.id, ports: try XCTUnwrap(reopened.graph.processing.modelDownload))
            await resumed.load()
            XCTAssertEqual(resumed.plan?.missing, [.speakers], "No speech download even with speech models missing")
            XCTAssertTrue(resumed.identifiesSpeakers)
            await resumed.download()
            await reopened.graph.processing.coordinator?.awaitIdle()
            XCTAssertEqual(analyzer.analyzeCount, 1, "Accepted retry ran only the speaker step")
            XCTAssertNil(reopened.graph.processing.state.jobs[note.id])
            let saved = try NoteRepository(root: test.root).load().notes.first { $0.id == note.id }
            XCTAssertEqual(saved?.transcript, note.transcript, "Words and timings survive consent and restart")
        }
    }

    private func downloadKind(_ note: Note, job: Job?) throws -> JobKind {
        let banner = try XCTUnwrap(NoteBanners.banners(note, job: job, mode: NoteMode.of(note, job: job),
            facts: NoteBannerFacts(speakerModelsMissing: true), failureText: { $0.code }).first { $0.kind == .txOneVoice })
        XCTAssertEqual(banner.actions, [.download])
        var screen = NoteScreenState()
        guard case .transcribe(let kind) = screen.bannerAction(.download, note: note, job: job) else {
            XCTFail("Expected the speaker-only Download action")
            throw XCTUnwrapError()
        }
        XCTAssertEqual(kind, .speakersOnly)
        return kind
    }

    private struct XCTUnwrapError: Error {}

    /// Run the actual job after declining the real speaker consent plan. No synthetic failure flag is injected.
    private func transcribeDecliningSpeakerModels(_ test: TestGraph) async throws -> Note {
        var note = Note(title: "English discussion", audioFilename: "audio.caf")
        note.duration = 2
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        test.graph.settings.identifySpeakers = true
        test.graph.settings.recordConsent() // Speech only; speaker consent below is declined.
        let consent = ModelDownloadModel(noteID: note.id, ports: try XCTUnwrap(test.graph.processing.modelDownload))
        await consent.load()
        XCTAssertEqual(consent.plan?.missing, [.speakers])
        consent.notNow()
        XCTAssertFalse(test.graph.settings.speakerDownloadsAllowed)
        await test.graph.processing.transcribe(note.id)
        await test.graph.processing.coordinator?.awaitIdle()
        let saved = try XCTUnwrap(try NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(saved.status, .ready)
        return saved
    }

    func testMissingSpeakerBannerQueuesOnlySpeakerConsentWithSpeechAlsoMissing() async throws {
        let speech = FakeTranscriber(.fails(.failed(.unknown)), status: .notDownloaded, recognizer: .parakeet)
        let test = TestGraph(transcriber: speech, analyzer: FakeAnalyzer(modelIdentity: nil))
        defer { test.tearDown() }
        var note = Note(title: "English discussion", audioFilename: "audio.caf")
        note.duration = 2
        note.status = .ready
        note.transcript = [.init(text: "Hello.", start: 0, end: 1)]
        note.speakerAnalysisFailure = .speakers
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        await test.graph.processing.models.refresh()
        XCTAssertEqual(test.graph.processing.models.status(of: .speakers), .notDownloaded)
        let banner = try XCTUnwrap(NoteBanners.banners(note, job: nil, mode: NoteMode.of(note, job: nil),
            facts: NoteBannerFacts(speakerModelsMissing: true), failureText: { $0.code }).first)
        XCTAssertEqual(banner.actions, [.download])
        var screen = NoteScreenState()
        let effect = screen.bannerAction(.download, note: note, job: nil)
        guard case .transcribe(let kind) = effect else { return XCTFail("Expected speaker download action") }
        XCTAssertEqual(kind, .speakersOnly)
        let outcome = await test.graph.processing.transcribe(note.id, kind: kind)
        XCTAssertEqual(outcome, .needsConsent)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.kind, .speakersOnly)
        let ports = try XCTUnwrap(test.graph.processing.modelDownload)
        let model = ModelDownloadModel(noteID: note.id, ports: ports)
        await model.load()
        XCTAssertEqual(model.plan?.missing, [.speakers])
        XCTAssertTrue(model.identifiesSpeakers)
        XCTAssertNil(model.speechLanguage)
        XCTAssertEqual(test.graph.library.note(note.id)?.transcript, note.transcript)
        XCTAssertFalse(test.graph.settings.downloadsAllowed)
        XCTAssertFalse(test.graph.settings.speakerDownloadsAllowed)
    }
}
