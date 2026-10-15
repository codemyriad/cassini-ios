import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The rules of `VoicesStore` over real note and voice files (`VoicesStoreTests` has the naming and saved-voice
/// flows): what Name a speaker is given, the trashed notes left out of matching, the Forget everyone generation
/// guard, and why a save is refused.
@MainActor @Suite(.serialized) final class VoicesStoreRulesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "cassini.tests.\(UUID().uuidString)"
    let clock = FakeClock(now: Date(timeIntervalSince1970: 1_000))
    let print = SpeakerPrint(speakerID: "a", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 10)
    let library: LibraryStore
    let settings: SettingsStore
    let voices: VoicesStore

    init() {
        library = LibraryStore(root: root) { _ in }
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, defaultLanguage: "en-US")
        voices = VoicesStore(library: library, settings: settings, clock: clock)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func start(_ notes: Note...) async throws {
        for note in notes { try await library.noteStore?.save(note) }
        await library.load()
        #expect(await voices.load())
    }

    /// Speaker a says two passages (11 s), b one, and c nothing.
    private func conversation() -> Note {
        var note = Note(title: "Conversation")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Bruno"), NoteSpeaker(id: "c", name: "Speaker 3")]
        note.transcript = [.init(text: "Hello there", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"),
                           .init(text: "Yes", start: 8, end: 9, speaker: "Bruno", speakerID: "b"),
                           .init(text: "Again", start: 9, end: 12, speaker: "Speaker 1", speakerID: "a"),
                           .init(text: "", start: 12, end: 13, speaker: "Speaker 3", speakerID: "c")]
        return note
    }

    @Test func theNamingInputDescribesTheSpeakerAndWhoItCanMergeInto() async throws {
        let note = conversation()
        try await start(note)
        let bare = try #require(await voices.namingInput(noteID: note.id, speakerID: "a"))
        #expect(bare.label == "Speaker 1" && bare.namedLabel == nil)
        #expect(bare.speakingTime == 11)
        #expect(bare.mergeTargets.map(\.speakerID) == ["b"], "a speaker who says nothing is no merge target")
        #expect(bare.print == nil && !bare.voiceModelReady, "no print and no analysis model yet")

        try await voices.store?.savePrints([print], noteID: note.id)
        let printed = try #require(await voices.namingInput(noteID: note.id, speakerID: "a"))
        #expect(printed.print == print && printed.voiceModelReady)

        // A print of the FluidAudio builds (WeSpeaker) counts as none: no voice of CAM++ can take it.
        let old = SpeakerPrint(speakerID: "b", model: "pyannote-community-1-wespeaker-coreml-v1:abc", vector: [1, 0],
                               speechSeconds: 10)
        try await voices.store?.savePrints([print, old], noteID: note.id)
        let stale = try #require(await voices.namingInput(noteID: note.id, speakerID: "b"))
        #expect(stale.print == nil && !stale.voiceModelReady)
        voices.printsReady = { true }
        #expect(await voices.namingInput(noteID: note.id, speakerID: "b")?.voiceModelReady == true,
                "the voiceprint model is installed: the next analysis makes a print")
        #expect(await voices.namingInput(noteID: note.id, speakerID: "z") == nil)
        #expect(await voices.namingInput(noteID: UUID(), speakerID: "a") == nil)
    }

    @Test func aSaveIsRefusedWithoutAPrintOrWhileTheVoicesAreReadOnly() async throws {
        let note = conversation()
        try await start(note)
        await #expect(throws: VoicesStore.SaveFailure.self) {
            try await voices.perform([.rememberVoice(speakerID: "a", voiceID: nil, name: "Anna")], noteID: note.id, speakerID: "a")
        }
        do throws(VoicesStore.SaveFailure) {
            try await voices.perform([.rememberVoice(speakerID: "a", voiceID: nil, name: "Anna")], noteID: note.id, speakerID: "a")
        } catch {
            guard case .tooLittleSpeech = error.reason else { Issue.record("\(error.reason)"); return }
        }
        #expect(voices.savedVoices.isEmpty)
        #expect(library.note(note.id)?.speakers?.first?.name == "Speaker 1", "nothing was changed")
    }

    /// A saved voice heard only in a note in Recently Deleted is neither suggested nor matched.
    @Test func voicesOfTrashedNotesAreLeftOutOfMatching() async throws {
        var source = Note(title: "Known person")
        source.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        source.transcript = [.init(text: "Reference", start: 0, end: 10, speaker: "Alex", speakerID: "a")]
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10)]
        try await start(source, target)
        try await voices.store?.savePrints([print], noteID: source.id)
        try await voices.perform([.rememberVoice(speakerID: "a", voiceID: nil, name: "Alex")], noteID: source.id, speakerID: "a")
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print])

        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: settings.voicesGeneration)
        #expect(library.note(target.id)?.speakers?.first?.suggestedVoiceID == voices.savedVoices.first?.id)

        library.update(source.id) { $0.trashedAt = Date(timeIntervalSince1970: 900) }
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: settings.voicesGeneration)
        #expect(library.note(target.id)?.speakers?.first?.suggestedVoiceID == nil)
    }

    /// An analysis that began before Forget everyone keeps no voiceprints and matches nobody; its speakers stay.
    @Test func anAnalysisOfAnOlderGenerationKeepsNoPrints() async throws {
        var note = Note(title: "Conversation")
        note.transcript = [.init(text: "Hello", start: 0, end: 12)]
        try await start(note)
        let generation = settings.voicesGeneration
        _ = await voices.forgetEveryone()
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "late", start: 0, end: 12)],
                                       prints: [.init(speakerID: "late", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 12)])
        try await voices.applySpeakerAnalysis(analysis, to: note.id, generation: generation)
        #expect(library.note(note.id)?.speakers?.count == 1)
        #expect(try await voices.store?.prints(noteID: note.id) == [])

        try await voices.applySpeakerAnalysis(analysis, to: note.id, generation: settings.voicesGeneration)
        #expect(try await voices.store?.prints(noteID: note.id).count == 1, "the current generation keeps them")
    }

    /// An analysis of a note in Recently Deleted changes nothing.
    @Test func anAnalysisOfATrashedNoteIsDropped() async throws {
        var note = Note(title: "Conversation")
        note.transcript = [.init(text: "Hello", start: 0, end: 12)]
        note.trashedAt = Date(timeIntervalSince1970: 900)
        try await start(note)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "s", start: 0, end: 12)], prints: [print])
        try await voices.applySpeakerAnalysis(analysis, to: note.id, generation: settings.voicesGeneration)
        #expect(library.note(note.id)?.speakers == nil)
        #expect(try await voices.store?.prints(noteID: note.id) == [])
    }

    /// Forget everyone that starts while an analysis reads the note's prints: the analysis writes no print and links
    /// no voice after the wipe (Android checks the generation inside the voice-file lock when it adopts the prints).
    @Test func forgetEveryoneDuringAnAnalysisLeavesNoPrintAndNoLink() async throws {
        var source = Note(title: "Known person")
        source.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        source.transcript = [.init(text: "Reference", start: 0, end: 10, speaker: "Alex", speakerID: "a")]
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10)]
        try await start(source, target)
        try await voices.store?.savePrints([print], noteID: source.id)
        try await voices.perform([.rememberVoice(speakerID: "a", voiceID: nil, name: "Alex")], noteID: source.id, speakerID: "a")
        settings.automaticallyNameVoices = true
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print])

        // The analysis suspends on its read of the prints; Forget everyone runs on the main actor meanwhile.
        let generation = settings.voicesGeneration
        let analysing = Task { try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation) }
        let forgetting = Task { await voices.forgetEveryone() }
        try await analysing.value
        #expect(await forgetting.value == .done)
        await library.settle()

        #expect(try await voices.store?.prints(noteID: target.id) == [], "no print outlives Forget everyone")
        #expect(voices.savedVoices.isEmpty)
        let speakers = try #require(library.note(target.id)?.speakers)
        #expect(speakers.count == 1, "the analysis still attributes the passages")
        #expect(speakers.allSatisfy { $0.match == .unmatched && $0.name == "Speaker 1" }, "no link to a forgotten voice comes back")
    }
}
