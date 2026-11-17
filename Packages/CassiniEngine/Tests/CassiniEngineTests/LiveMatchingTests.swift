import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@Suite struct LiveMatchingTests {
    @Test(arguments: [false, true]) func removingVoicesClearsUnconfirmedNamesEvenWithoutADuePrint(duringPrint: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), saved = TranscriptionJobLiveNamesTests.voice("Alex", TranscriptionJobLiveNamesTests.near(0))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        let drafts = DraftNamesStore(notes: try NoteStore(root: root))
        let expected = DraftNames.empty.rename("manual", "Manual")
            .confirm("confirmed", voice: UUID(), name: "Confirmed", generation: 1, score: 1)
        drafts.mutate(id) { _ in expected.applyLive(["auto": LiveMatch(saved.id, 1, .auto),
            "suggestion": LiveMatch(saved.id, 0.6, .suggested)], names: [saved.id: saved.name]) }
        let voices = Mutex(duringPrint ? [saved] : [])
        let engine = FakeSpeakerEngines(vector: { _ in
            voices.withLock { $0 = [] }
            return TranscriptionJobLiveNamesTests.near(0)
        }, turns: { _, _ in [] })
        let matching = LiveMatching(noteID: id, drafts: drafts, voices: { voices.withLock { $0 } }, autoName: true)
        let windows: [String: [PrintWindow]] = duringPrint ? ["auto": [.init(0, 5)]] : [:]
        try matching.round(windows: windows, clips: PcmAudio([0, 0, 0, 0, 0], sampleRate: 1), engines: engine, active: {})
        #expect(drafts.current(id) == expected)
        #expect(engine.printRequests.count == (duringPrint ? 1 : 0))
        #expect(DraftNamesStore(notes: try NoteStore(root: root)).current(id) == expected)
    }
}
