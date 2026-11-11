import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class NoteSpeakerDownloadTests: XCTestCase {
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
