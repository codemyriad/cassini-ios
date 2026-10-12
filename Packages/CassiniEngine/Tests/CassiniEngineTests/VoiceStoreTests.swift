import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct VoiceStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    @Test func removingANotesEvidenceDropsItsSamplesAndPrints() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let kept = UUID(), removed = UUID()
        let print = SpeakerPrint(speakerID: "S1", model: "m", vector: [1, 0], speechSeconds: 8)
        try await store.save([SavedVoice(name: "Luca", samples: [VoiceSample(noteID: kept, print: print),
                                                                  VoiceSample(noteID: removed, print: print)])])
        try await store.savePrints([print], noteID: removed)
        #expect(await store.hasEvidence())

        try await store.removeEvidence(noteID: removed)
        #expect(try await store.prints(noteID: removed).isEmpty)
        #expect(try await VoiceStore(root: root).voices().first?.samples.map(\.noteID) == [kept])
    }

    @Test func anUnchangedMutateKeepsTheVoices() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        try await store.save([SavedVoice(name: "Ada", samples: [])])
        let same = try await store.mutate { _ in }
        #expect(same.map(\.name) == ["Ada"])
        try await store.mutate { $0[0].name = "Grace" }
        #expect(await store.voices().map(\.name) == ["Grace"])
    }
}
