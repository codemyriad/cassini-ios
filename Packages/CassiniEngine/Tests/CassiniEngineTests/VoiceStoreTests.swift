import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct VoiceStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let print = SpeakerPrint(speakerID: "S1", model: "m", vector: [1, 0], speechSeconds: 8)

    func voice(_ name: String, notes: [UUID] = [UUID()]) -> SavedVoice {
        SavedVoice(name: name, samples: notes.map { VoiceSample(noteID: $0, print: print) })
    }

    @Test func removingANotesEvidenceDropsItsSamplesAndPrints() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let kept = UUID(), removed = UUID()
        try await store.save([voice("Luca", notes: [kept, removed])])
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

    // ports: VoiceRepositoryTest#renameValidatesAndKeepsTheVoice
    @Test func renameValidatesAndKeepsTheVoice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let luca = voice("Luca")
        try await store.save([luca])
        #expect(await store.rename(luca.id, name: "  ") == .invalid)
        #expect(await store.rename(luca.id, name: String(repeating: "x", count: 81)) == .invalid)
        #expect(await store.rename(UUID(), name: "Ugo") == .notFound)
        #expect(await store.rename(luca.id, name: "  Luca B. ") == .done)
        let saved = try #require(try await VoiceStore(root: root).voices().first)
        #expect(saved.name == "Luca B.")
        #expect(saved.samples == luca.samples)
    }

    // ports: VoiceRepositoryTest#forgetScrubsSealedAndPendingFilesLinksAndDrafts
    /// The notes' links are dropped by the app (`Note.unlinkVoice`, hosted tests); here the voice goes.
    @Test func forgetRemovesOnlyThatVoice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let luca = voice("Luca"), anna = voice("Anna")
        try await store.save([luca, anna])
        #expect(await store.forget(luca.id) == .done)
        #expect(await store.voices().map(\.id) == [anna.id])
        #expect(await store.forget(luca.id) == .notFound)
    }

    // ports: VoiceRepositoryTest#forgetEveryoneBumpsTheGenerationAndDeletesEveryPrint
    @Test func forgetEveryoneDeletesEveryPrint() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let note = UUID()
        try await store.save([voice("Luca", notes: [note])])
        try await store.appendPrints([print], noteID: note, ifForgottenCount: 0)
        #expect(await store.forgetEveryone() == .done)
        let snapshot = await store.snapshot()
        #expect(snapshot.voices.isEmpty && !snapshot.hasEvidence && !snapshot.isReadOnly)
        #expect(await store.forgetEveryone() == .done, "a second run is harmless")
    }

    // ports: VoiceRepositoryTest#aNewerPeopleFileStaysReadOnly
    @Test func aNewerFileRefusesEveryEdit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PrivateVoices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"voices":[]}"#.utf8).write(to: folder.appendingPathComponent("voices.json"))
        let store = try VoiceStore(root: root)
        let snapshot = await store.snapshot()
        #expect(snapshot.problem == .newer && snapshot.isReadOnly && !snapshot.canForgetEveryone)
        #expect(await store.rename(UUID(), name: "Y") == .readOnly)
        #expect(await store.forget(UUID()) == .readOnly)
        #expect(await store.forgetEveryone() == .readOnly)
    }

    @Test func appendingPrintsKeepsThoseOfEarlierAnalyses() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let note = UUID()
        var later = print
        later.speakerID = "S2"
        try await store.appendPrints([print], noteID: note, ifForgottenCount: 0)
        try await store.appendPrints([later], noteID: note, ifForgottenCount: 0)
        #expect(try await store.prints(noteID: note).map(\.speakerID) == ["S1", "S2"])
        #expect(try await store.sweepOrphans(keeping: []) == [note])
    }

    /// An analysis that read the prints before Forget everyone writes none of its own after it.
    @Test func printsReadBeforeAForgetAreNotWrittenAfterIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let note = UUID()
        let (_, count) = await store.printsForAnalysis(noteID: note)
        #expect(await store.forgetEveryone() == .done)
        #expect(try await store.appendPrints([print], noteID: note, ifForgottenCount: count) == false)
        #expect(try await store.prints(noteID: note).isEmpty)
        #expect(await !store.snapshot().hasEvidence)
    }
}
