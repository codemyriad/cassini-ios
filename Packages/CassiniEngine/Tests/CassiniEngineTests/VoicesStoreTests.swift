import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The library, the settings and the saved voices of one launch over a temporary root, as the app's launch builds
/// and loads them: the notes, the saved voices, then the sweep of orphaned voiceprints.
@MainActor final class VoicesHarness {
    let root: URL
    let suite: String
    let clock: FakeClock
    let library: LibraryStore
    let settings: SettingsStore
    let voices: VoicesStore
    /// The failed note writes the Library reported.
    private(set) var failures: [any Error] = []

    init(root: URL? = nil, suite: String? = nil, clock: FakeClock = FakeClock(now: Date(timeIntervalSince1970: 1_000))) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.suite = suite ?? "cassini.voices-tests.\(UUID().uuidString)"
        self.clock = clock
        var report: (any Error) -> Void = { _ in }
        library = LibraryStore(root: self.root) { report($0) }
        settings = SettingsStore(defaults: UserDefaults(suiteName: self.suite)!, clock: clock, defaultLanguage: "en-US")
        voices = VoicesStore(library: library, settings: settings, clock: clock)
        report = { [weak self] in self?.failures.append($0) }
    }

    /// The launch's steps for the voices; false when the sweep failed.
    @discardableResult func start() async -> Bool {
        await library.load()
        if library.loadFailure == nil { await voices.load() }
        return (try? await voices.sweepOrphans()) != nil
    }

    /// The next launch over the same files and preferences.
    func reopened() -> VoicesHarness { VoicesHarness(root: root, suite: suite, clock: clock) }

    var voicesFolder: URL { root.appendingPathComponent("PrivateVoices", isDirectory: true) }

    func stored(_ id: UUID) throws -> Note? { try NoteRepository(root: root).load().notes.first { $0.id == id } }

    func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: voicesFolder.path)
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

/// Naming, saved voices and speaker analysis over real note and voice files: the note and the voice files together
/// (Android `VoiceRepositoryTest` and `NoteViewModelTest`'s naming side). The analysis racing a Forget everyone
/// through the queue stays a hosted test (`CassiniTests/VoicesStoreTests`).
@MainActor @Suite(.serialized) struct VoicesStoreTests {
    let print = SpeakerPrint(speakerID: "a", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 10)
    let h = VoicesHarness()

    /// A note whose speaker "a" says two passages, with its print on disk.
    private func namedNote(print: SpeakerPrint? = nil) async throws -> Note {
        var note = Note(title: "Speaker session")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"),
                           .init(text: "Again", start: 9, end: 12, speaker: "Speaker 1", speakerID: "a")]
        try NoteRepository(root: h.root).save(note)
        await h.start()
        try await h.voices.store?.savePrints([print ?? self.print], noteID: note.id)
        return note
    }

    private func remember(_ name: String, speaker: String = "a", in note: UUID, voices: VoicesStore) async throws(VoicesStore.SaveFailure) {
        try await voices.perform([.relabel(speakerID: speaker, name: name), .rememberVoice(speakerID: speaker, voiceID: nil, name: name)],
                                 noteID: note, speakerID: speaker)
    }

    /// Android semantics: renaming a saved voice keeps the names already in notes; forgetting keeps them too.
    @Test func namingPersistsAndRenameOrForgetKeepTheNamesInNotes() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        try await remember("Alex", in: note.id, voices: h.voices)
        #expect(h.library.note(note.id)?.transcript.map(\.speaker) == ["Alex", "Alex"])
        await h.library.settle()

        let second = h.reopened()
        await second.start()
        let voices = second.voices, library = second.library
        let voice = try #require(voices.savedVoices.first)
        #expect(library.note(note.id)?.speakers?.first?.match == .confirmed(voice: voice.id, score: 1))
        #expect(voices.summaries.first?.notes == 1)

        #expect(await voices.rename(voice.id, name: "Alice") == .done)
        #expect(voices.savedVoices.first?.name == "Alice")
        #expect(library.note(note.id)?.transcript.map(\.speaker) == ["Alex", "Alex"], "names already in notes stay")

        #expect(await voices.forget(voice.id) == .done)
        #expect(voices.savedVoices.isEmpty)
        #expect(library.note(note.id)?.speakers?.first?.match == .unmatched)
        #expect(library.note(note.id)?.transcript.first?.speaker == "Alex")
    }

    // ports: VoiceRepositoryTest#forgetEveryoneBumpsTheGenerationAndDeletesEveryPrint (through the notes)
    @Test func forgetEveryoneAdvancesTheGenerationAndDeletesEveryPrint() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        try await remember("Alex", in: note.id, voices: h.voices)
        let generation = h.settings.voicesGeneration
        #expect(await h.voices.forgetEveryone() == .done)
        #expect(h.settings.voicesGeneration > generation)
        #expect(h.voices.savedVoices.isEmpty)
        #expect(!h.voices.hasEvidence)
        #expect(try await h.voices.store?.prints(noteID: note.id) == [])
        #expect(h.library.note(note.id)?.speakers?.first?.match == .unmatched)
    }

    @Test(arguments: [false, true]) func recognitionOffKeepsManualNamesDuringReanalysis(remembered: Bool) async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        if remembered { try await remember("Alex", in: note.id, voices: h.voices) }
        else { try await h.voices.perform([.relabel(speakerID: "a", name: "Alex")], noteID: note.id, speakerID: "a") }
        h.settings.recogniseSavedVoices = false
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "new", start: 0, end: 12)],
            prints: [.init(speakerID: "new", model: print.model, vector: print.vector, speechSeconds: 12)])
        try await h.voices.applySpeakerAnalysis(analysis, to: note.id, generation: h.settings.voicesGeneration)
        let updated = try #require(h.library.note(note.id))
        #expect(updated.transcript.map(\.speaker) == ["Alex", "Alex"])
        #expect(updated.speakers?.first?.match == .unmatched)
        #expect(h.voices.savedVoices.count == (remembered ? 1 : 0))
    }

    @Test func voiceSuggestionsAutoNamingAndTrashedEvidence() async throws {
        defer { h.tearDown() }
        let repository = try NoteRepository(root: h.root)
        var source = Note(title: "Known person")
        source.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        source.transcript = [.init(text: "Reference", start: 0, end: 10, speaker: "Alex", speakerID: "a")]
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10)]
        try repository.save(source); try repository.save(target)
        await h.start()
        let voices = h.voices, library = h.library, settings = h.settings
        try await voices.store?.savePrints([print], noteID: source.id)
        try await voices.perform([.rememberVoice(speakerID: "a", voiceID: nil, name: "Alex")], noteID: source.id, speakerID: "a")
        let voiceID = try #require(voices.savedVoices.first?.id)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print])
        let generation = settings.voicesGeneration
        settings.automaticallyNameVoices = true
        settings.recogniseSavedVoices = false
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        #expect(library.note(target.id)?.speakers?.first?.suggestedVoiceID == nil)
        #expect(library.note(target.id)?.speakers?.first?.linkedVoiceID == nil)
        #expect(library.note(target.id)?.transcript.first?.speaker != "Alex")
        #expect(voices.savedVoices.count == 1, "Recognition off keeps saved voices")
        settings.recogniseSavedVoices = true
        settings.automaticallyNameVoices = false
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        #expect(library.note(target.id)?.speakers?.first?.suggestedVoiceID == voiceID)
        #expect(library.note(target.id)?.speakers?.first?.linkedVoiceID == nil)
        let suggested = try #require(library.note(target.id))
        #expect(voices.suggestions(for: suggested).first?.voiceName == "Alex")
        settings.automaticallyNameVoices = true
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        #expect(library.note(target.id)?.transcript.first?.speaker == "Alex")
        #expect(library.note(target.id)?.speakers?.first?.linkedVoiceID == voiceID)
        #expect(voices.savedVoices.first?.samples.count == 1, "An automatic match must not enrol new evidence")
        library.update(source.id) { $0.trashedAt = Date(timeIntervalSince1970: 900) }
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        #expect(library.note(target.id)?.speakers?.first?.suggestedVoiceID == nil)
        #expect(library.note(target.id)?.speakers?.first?.linkedVoiceID == nil)
    }

    /// Acceptance: "Yes, Alex" names the speaker and remembers its print; "Not Alex" stays after Identify speakers.
    @Test func aSuggestionIsAcceptedOrRejectedForGood() async throws {
        defer { h.tearDown() }
        let source = try await namedNote()
        let voices = h.voices, library = h.library
        try await remember("Alex", in: source.id, voices: voices)
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10), .init(text: "More", start: 10, end: 20)]
        try await library.insert(target)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10), .init(speakerID: "b", start: 10, end: 20)],
                                       prints: [print])
        let generation = h.settings.voicesGeneration
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        let targetNote = try #require(library.note(target.id))
        let suggestion = try #require(voices.suggestions(for: targetNote).first)

        try await voices.reject(suggestion, noteID: target.id)
        let rejected = try #require(library.note(target.id))
        #expect(voices.suggestions(for: rejected).isEmpty)
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        let again = try #require(library.note(target.id)?.speakers?.first)
        #expect(again.match == .unmatched, "a rejected voice stays rejected after another analysis")
        #expect(again.excludedVoiceIDs == [suggestion.voiceID])

        // Another note: Yes names and confirms.
        var other = Note(title: "Third")
        other.transcript = [.init(text: "Hi", start: 0, end: 10)]
        try await library.insert(other)
        try await voices.applySpeakerAnalysis(SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print]),
                                              to: other.id, generation: generation)
        let otherNote = try #require(library.note(other.id))
        let yes = try #require(voices.suggestions(for: otherNote).first)
        try await voices.accept(yes, noteID: other.id)
        #expect(library.note(other.id)?.transcript.first?.speaker == "Alex")
        #expect(library.note(other.id)?.speakers?.first?.match.voiceID == yes.voiceID)
        #expect(voices.savedVoices.first?.samples.count == 2)
    }

    /// A streaming run's draft names go into the note with its speakers (Android's adopt): a "Not Alex" is never
    /// matched, the user's name wins over a match to someone else, a stored placeholder is no name, and a Remember
    /// choice enrols the speaker's print once the note holds it.
    @Test func theDraftNamesGoIntoTheNoteWithTheSpeakers() async throws {
        defer { h.tearDown() }
        let source = try await namedNote()
        let voices = h.voices, library = h.library
        try await remember("Alex", in: source.id, voices: voices)
        let alex = try #require(voices.savedVoices.first?.id)
        h.settings.automaticallyNameVoices = true
        var target = Note(title: "Streamed")
        target.transcript = [.init(text: "Uno", start: 0, end: 10), .init(text: "Due", start: 10, end: 20),
                             .init(text: "Tre", start: 20, end: 30)]
        try await library.insert(target)
        var streamed = target.transcript
        for (index, id) in ["a", "b", "c"].enumerated() { streamed[index].speakerID = id }
        // a and c sound like Alex; b is someone else.
        let prints = [SpeakerPrint(speakerID: "a", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 10),
                      SpeakerPrint(speakerID: "b", model: VoiceprintModel.sha256, vector: [0, 1], speechSeconds: 10),
                      SpeakerPrint(speakerID: "c", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 10)]
        let names = DraftNames(labels: ["b": "Bruno", "c": "Speaker 3"], remembered: ["b": .new],
                               generation: h.settings.voicesGeneration, rejected: ["a": [alex]])
        let analysis = SpeakerAnalysis(turns: ["a", "b", "c"].enumerated().map {
            .init(speakerID: $0.element, start: Double($0.offset) * 10, end: Double($0.offset) * 10 + 10)
        }, prints: prints, transcript: streamed, names: names)

        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: h.settings.voicesGeneration)

        let note = try #require(library.note(target.id))
        let speakers = Dictionary(uniqueKeysWithValues: (note.speakers ?? []).map { ($0.id, $0) })
        #expect(speakers["a"]?.match == .unmatched, "Not Alex")
        #expect(speakers["a"]?.excludedVoiceIDs == [alex])
        #expect(speakers["a"]?.name == "Speaker 1")
        #expect(speakers["c"]?.match.voiceID == alex, "a stored placeholder is no name: the match names c")
        let bruno = try #require(voices.savedVoices.first { $0.name == "Bruno" })
        #expect(speakers["b"]?.name == "Bruno")
        #expect(speakers["b"]?.linkedVoiceID == bruno.id, "Remember made Bruno's voice from b's print")
        #expect(bruno.samples.map(\.print.vector) == [[0, 1]])
        #expect(note.transcript.map(\.speaker) == ["Speaker 1", "Bruno", "Alex"])
    }

    @Test func aDraftNameWinsOverAMatchToSomeoneElse() async throws {
        defer { h.tearDown() }
        let source = try await namedNote()
        let voices = h.voices, library = h.library
        try await remember("Alex", in: source.id, voices: voices)
        h.settings.automaticallyNameVoices = true
        var target = Note(title: "Streamed")
        target.transcript = [.init(text: "Uno", start: 0, end: 10)]
        try await library.insert(target)
        var streamed = target.transcript
        streamed[0].speakerID = "a"
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print],
                                       transcript: streamed,
                                       names: DraftNames(labels: ["a": "Chiara"], generation: h.settings.voicesGeneration))

        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: h.settings.voicesGeneration)

        let speaker = try #require(library.note(target.id)?.speakers?.first)
        #expect(speaker.name == "Chiara")
        #expect(speaker.match == .unmatched)
        #expect(voices.savedVoices.map(\.name) == ["Alex"], "nothing to enrol without a Remember choice")
    }

    @Test func aRememberChoiceFromBeforeForgetEveryoneEnrolsNothing() async throws {
        defer { h.tearDown() }
        _ = try await namedNote()
        let library = h.library
        var target = Note(title: "Streamed")
        target.transcript = [.init(text: "Uno", start: 0, end: 10)]
        try await library.insert(target)
        var streamed = target.transcript
        streamed[0].speakerID = "a"
        let generation = h.settings.voicesGeneration
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print],
                                       transcript: streamed,
                                       names: DraftNames(labels: ["a": "Chiara"], remembered: ["a": .new],
                                                         generation: generation - 1))

        try await h.voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)

        #expect(library.note(target.id)?.speakers?.first?.name == "Chiara")
        #expect(h.voices.savedVoices.isEmpty)
    }

    /// Acceptance: a note save failure leaves no orphan voice.
    @Test func aNoteThatCannotBeSavedLeavesNoVoice() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        let directory = h.root.appendingPathComponent(note.id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        do throws(VoicesStore.SaveFailure) {
            try await remember("Alex", in: note.id, voices: h.voices)
            Issue.record("the name was saved into a folder that can't be written")
        } catch {
            guard case .noteNotSaved = error.reason else { Issue.record("\(error.reason)"); return }
        }
        #expect(h.voices.savedVoices.isEmpty)
        #expect(try await h.voices.store?.voices() == [])
        #expect(h.library.note(note.id)?.speakers?.first?.name == "Speaker 1")
    }

    /// Confirmed as someone else: the old sample is taken back; a voice left without samples is forgotten everywhere.
    @Test func keepingTheSavedNameUnenrolsAndMakesANewVoice() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        let voices = h.voices
        try await remember("Anna", in: note.id, voices: voices)
        let anna = try #require(voices.savedVoices.first)
        let input = try #require(await voices.namingInput(noteID: note.id, speakerID: "a"))
        var state = SpeakerNaming.open(input)
        state = try #require(SpeakerNaming.reduce(state, .nameChanged("Annette")).state)
        state = try #require(SpeakerNaming.reduce(state, .keepSaved).state)
        let effects = SpeakerNaming.reduce(state, .save).effects.filter { $0 != .close }
        try await voices.perform(effects, noteID: note.id, speakerID: "a")

        #expect(voices.savedVoices.map(\.name) == ["Annette"])
        #expect(voices.savedVoices.first?.id != anna.id, "Anna had only this sample and is forgotten")
        #expect(h.library.note(note.id)?.speakers?.first?.match.voiceID == voices.savedVoices.first?.id)
    }

    @Test func namingASpeakerKeepsWhatAnEngineWriterSavedBeforeTheNameLanded() async throws {
        defer { h.tearDown() }
        var note = Note(title: "Speaker session")
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a")]
        try NoteRepository(root: h.root).save(note)
        await h.start()
        let library = h.library, voices = h.voices
        let noteStore = try #require(library.noteStore)

        let naming = Task { try await voices.perform([.relabel(speakerID: "a", name: "Alex")], noteID: note.id, speakerID: "a") }
        // A transcription job saves the note while the name is on its way to the store.
        try await noteStore.mutate(note.id) { $0.status = .ready; $0.title = "Retitled by a job" }
        try await naming.value
        await library.settle()

        let stored = try #require(try h.stored(note.id))
        #expect(stored.title == "Retitled by a job")
        #expect(stored.status == .ready)
        #expect(stored.speakers?.map(\.name) == ["Alex"])
        #expect(stored.transcript.map(\.speaker) == ["Alex"])
        #expect(library.note(note.id) == stored)
        #expect(h.failures.isEmpty)
    }

    @Test func aSpeakerAnalysisKeepsWhatAnEngineWriterSavedBeforeItLanded() async throws {
        defer { h.tearDown() }
        var note = Note(title: "Conversation")
        note.status = .ready
        note.transcript = [.init(text: "First", start: 0, end: 4), .init(text: "Second", start: 5, end: 9)]
        try NoteRepository(root: h.root).save(note)
        await h.start()
        let library = h.library, voices = h.voices
        let noteStore = try #require(library.noteStore)
        let analysis = SpeakerAnalysis(
            turns: [.init(speakerID: "x", start: 0, end: 4.5), .init(speakerID: "y", start: 4.5, end: 9)], prints: [])

        let analyzing = Task { try await voices.applySpeakerAnalysis(analysis, to: note.id, generation: h.settings.voicesGeneration) }
        // An engine writer saves the note while the analysis is on its way to the store.
        try await noteStore.mutate(note.id) { $0.isFavorite = true; $0.title = "Retitled by a job" }
        try await analyzing.value
        await library.settle()

        let stored = try #require(try h.stored(note.id))
        #expect(stored.title == "Retitled by a job")
        #expect(stored.isFavorite)
        #expect(stored.speakers?.map(\.name) == ["Speaker 1", "Speaker 2"])
        #expect(stored.transcript.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(stored.versions?.map(\.kind) == [.beforeSpeakerAnalysis, .speakerAnalysis])
        #expect(stored.selectedVersionID == stored.versions?.last?.id)
        #expect(library.note(note.id) == stored)
        #expect(h.failures.isEmpty)
    }

    /// At launch, the voiceprints of notes that are gone are deleted.
    @Test func theLaunchSweepsThePrintsOfNotesThatAreGone() async throws {
        defer { h.tearDown() }
        let gone = UUID()
        try FileManager.default.createDirectory(at: h.voicesFolder, withIntermediateDirectories: true)
        let file = h.voicesFolder.appendingPathComponent(NoteVoiceCodec.fileName(gone))
        try NoteVoiceCodec.encode([print]).write(to: file)
        #expect(await h.start(), "the sweep ran")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // ports: VoiceRepositoryTest#aNewerPeopleFileStaysReadOnly (through the store; permanent deletion waits)
    @Test func aNewerVoicesFileIsReadOnly() async throws {
        defer { h.tearDown() }
        try FileManager.default.createDirectory(at: h.voicesFolder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"voices":[]}"#.utf8).write(to: h.voicesFolder.appendingPathComponent("voices.json"))
        await h.start()
        #expect(h.voices.isReadOnly)
        #expect(await h.voices.forgetEveryone() == .readOnly)
        await #expect(throws: VoicesStore.Unavailable.self) { try await h.voices.removeEvidence(noteID: UUID()) }
    }

    /// A note whose note.json can't be read now keeps its folder, and so keeps its voiceprints through the sweep.
    @Test func theLaunchSweepKeepsThePrintsOfNotesThatCouldNotBeRead() async throws {
        defer { h.tearDown() }
        let unreadable = UUID()
        let noteFolder = h.root.appendingPathComponent(unreadable.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteFolder, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":3}"#.utf8).write(to: noteFolder.appendingPathComponent(NoteRepository.metadataFilename))
        try FileManager.default.createDirectory(at: h.voicesFolder, withIntermediateDirectories: true)
        try NoteVoiceCodec.encode([print]).write(to: h.voicesFolder.appendingPathComponent(NoteVoiceCodec.fileName(unreadable)))
        #expect(await h.start())
        #expect(h.library.unreadableCount == 1)
        #expect(try await h.voices.store?.prints(noteID: unreadable) == [print])
    }

    /// While the saved voices can't be read, the list is not known: opening another version keeps every link.
    @Test func selectingAVersionWhileTheVoicesAreNewerKeepsTheLinks() async throws {
        defer { h.tearDown() }
        let alex = UUID()
        var note = Note(title: "Versions")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Alex", match: .confirmed(voice: alex, score: 1))]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Alex", speakerID: "a")]
        let first = UUID()
        note.saveCurrentVersion(.transcription, id: first)
        note.transcript = [.init(text: "Hello again", start: 0, end: 8, speaker: "Alex", speakerID: "a")]
        note.saveCurrentVersion(.speakerAnalysis)
        try NoteRepository(root: h.root).save(note)
        try FileManager.default.createDirectory(at: h.voicesFolder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"voices":[]}"#.utf8).write(to: h.voicesFolder.appendingPathComponent("voices.json"))
        await h.start()
        #expect(h.voices.isReadOnly)

        h.voices.selectTranscriptVersion(noteID: note.id, versionID: first)
        await h.library.settle()

        let stored = try #require(try h.stored(note.id))
        #expect(stored.selectedVersionID == first)
        #expect(stored.speakers?.first?.match == .confirmed(voice: alex, score: 1))
        #expect(stored.versions?.map { $0.speakers.first?.match } == [.confirmed(voice: alex, score: 1), .confirmed(voice: alex, score: 1)])
    }

    /// Two names saved at once (two suggestion cards, say) both start from the same saved voices; both are kept.
    @Test func overlappingNamesKeepBothVoices() async throws {
        defer { h.tearDown() }
        let repository = try NoteRepository(root: h.root)
        var notes: [Note] = []
        for title in ["One", "Two"] {
            var note = Note(title: title)
            note.status = .ready
            note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
            note.transcript = [.init(text: "Hello", start: 0, end: 10, speaker: "Speaker 1", speakerID: "a")]
            try repository.save(note)
            notes.append(note)
        }
        await h.start()
        let voices = h.voices
        try await voices.store?.savePrints([print], noteID: notes[0].id)
        try await voices.store?.savePrints([SpeakerPrint(speakerID: "a", model: VoiceprintModel.sha256, vector: [0, 1], speechSeconds: 10)],
                                           noteID: notes[1].id)

        let luca = Task { try await remember("Luca", in: notes[0].id, voices: voices) }
        let sam = Task { try await remember("Sam", in: notes[1].id, voices: voices) }
        try await luca.value
        try await sam.value
        await h.library.settle()

        let stored = try #require(await voices.store?.voices())
        #expect(Set(stored.map(\.name)) == ["Luca", "Sam"])
        for (note, name) in zip(notes, ["Luca", "Sam"]) {
            let voice = try #require(stored.first { $0.name == name })
            #expect(voice.samples.map(\.noteID) == [note.id])
            #expect(h.library.note(note.id)?.speakers?.first?.match.voiceID == voice.id)
        }
    }

    /// Acceptance: the note is written but the voices can't be; the note's links go back and the error is shown.
    @Test func aVoiceWriteThatFailsPutsTheNotesLinksBack() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        let voices = h.voices, library = h.library
        try await remember("Alex", in: note.id, voices: voices)
        let alex = try #require(voices.savedVoices.first)
        library.update(note.id) { $0.saveCurrentVersion(.speakerAnalysis) }
        await library.settle()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.voicesFolder.path)

        do throws(VoicesStore.SaveFailure) {
            // "Not Alex" on Alex's only sample would forget Alex everywhere.
            try await voices.perform([.reject(speakerID: "a", voiceID: alex.id, voiceName: "Alex", unenrol: true, restorePlaceholder: false)],
                                     noteID: note.id, speakerID: "a")
            Issue.record("the voices were written into a folder that can't be written")
        } catch {
            guard case .voiceNotSaved = error.reason else { Issue.record("\(error.reason)"); return }
        }
        await library.settle()
        let stored = try #require(try h.stored(note.id))
        #expect(stored.speakers?.first?.match == .confirmed(voice: alex.id, score: 1))
        #expect(stored.speakers?.first?.excludedVoiceIDs == [])
        #expect(stored.versions?.last?.speakers.first?.match == .confirmed(voice: alex.id, score: 1))
        #expect(voices.savedVoices == [alex])
    }

    /// Deleting a note for good takes its samples; a voice left with none is forgotten and unlinked everywhere.
    @Test func removingTheOnlyEvidenceOfAVoiceForgetsIt() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        try await remember("Alex", in: note.id, voices: h.voices)
        try await h.voices.removeEvidence(noteID: note.id)
        #expect(h.voices.savedVoices.isEmpty)
        #expect(h.library.note(note.id)?.speakers?.first?.match == .unmatched)
        #expect(h.library.note(note.id)?.speakers?.first?.name == "Alex")
    }

    /// A damaged list with no voiceprints left: Forget all voice data is still offered and starts the list again.
    @Test func aDamagedListWithoutPrintsCanStillBeForgotten() async throws {
        defer { h.tearDown() }
        try FileManager.default.createDirectory(at: h.voicesFolder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: h.voicesFolder.appendingPathComponent("voices.json"))
        await h.start()
        let voices = h.voices
        #expect(voices.snapshot.problem == .damaged)
        #expect(!voices.hasEvidence)
        #expect(voices.offersForgetAllData)
        #expect(await voices.forgetEveryone() == .done)
        #expect(!voices.isReadOnly)
        #expect(!voices.offersForgetAllData)
    }

    /// A Forget everyone that could not delete everything keeps the notes' links to the voices it kept.
    @Test func aForgetEveryoneThatFailsKeepsTheLinks() async throws {
        defer { h.tearDown() }
        let note = try await namedNote()
        try await remember("Alex", in: note.id, voices: h.voices)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.voicesFolder.path)

        let outcome = await h.voices.forgetEveryone()
        guard case .failed = outcome else { Issue.record("forgot everyone in a folder that can't be written: \(outcome)"); return }
        #expect(h.voices.savedVoices.count == 1)
        #expect(h.library.note(note.id)?.speakers?.first?.match.voiceID != nil)
    }

    // MARK: - Batch Save, Rollback & Undo (D-1167)

    /// Reassigning a confirmed speaker whose previous voice had only this sample deletes that voice and scrubs links
    /// across other notes; Undo restores the deleted voice, its sample, the confirmed link, and the scrubbed link.
    @Test func batchUndoRestoresReassignedSpeakerDeletedLastSampleVoiceAndScrubbedLinks() async throws {
        defer { h.tearDown() }
        let printA = SpeakerPrint(speakerID: "a", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 10)
        let printB = SpeakerPrint(speakerID: "b", model: VoiceprintModel.sha256, vector: [0, 1], speechSeconds: 10)
        let printOther = SpeakerPrint(speakerID: "x", model: VoiceprintModel.sha256, vector: [0.5, 0.5], speechSeconds: 10)

        var note = Note(title: "Primary")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript = [
            .init(text: "Hello", start: 0, end: 5, speaker: "Speaker 1", speakerID: "a"),
            .init(text: "Coffee", start: 6, end: 10, speaker: "Speaker 2", speakerID: "b"),
        ]
        var otherNote = Note(title: "Other")
        otherNote.status = .ready
        otherNote.speakers = [NoteSpeaker(id: "x", name: "Carol"), NoteSpeaker(id: "y", name: "Bob")]
        otherNote.transcript = [
            .init(text: "Hi", start: 0, end: 5, speaker: "Carol", speakerID: "x"),
            .init(text: "Yo", start: 6, end: 10, speaker: "Bob", speakerID: "y"),
        ]
        let repo = try NoteRepository(root: h.root)
        try repo.save(note)
        try repo.save(otherNote)
        await h.start()
        try await h.voices.store?.savePrints([printA, printB], noteID: note.id)
        try await h.voices.store?.savePrints([printOther], noteID: otherNote.id)

        // Enrol Bob (only sample = note/a) and Carol (only sample = otherNote/x).
        try await remember("Bob", speaker: "a", in: note.id, voices: h.voices)
        try await remember("Carol", speaker: "x", in: otherNote.id, voices: h.voices)
        let bob = try #require(h.voices.savedVoices.first { $0.name == "Bob" })
        let carol = try #require(h.voices.savedVoices.first { $0.name == "Carol" })

        // Give otherNote/y an automatic link to Bob so forgetting Bob scrubs it.
        _ = await h.library.commit(otherNote.id) { n in
            n.speakers?[1].match = .auto(voice: bob.id, score: 0.9)
        }
        await h.library.settle()

        // Batch: reassign a from Bob -> Carol (unenrol deletes Bob's last sample) AND mark b as background.
        let snapshot = try await h.voices.performBatch([
            .init(speakerID: "a", effects: [
                .unenrol(speakerID: "a"),
                .relabel(speakerID: "a", name: "Carol"),
                .rememberVoice(speakerID: "a", voiceID: carol.id, name: "Carol"),
            ]),
            .init(speakerID: "b", effects: [.setBackground(speakerID: "b", background: true)]),
        ], noteID: note.id)
        await h.library.settle()

        #expect(h.voices.voice(bob.id) == nil, "Bob had only a's sample and was forgotten")
        #expect(h.voices.voice(carol.id)?.samples.count == 2)
        #expect(h.library.note(otherNote.id)?.speaker("y")?.match == .unmatched, "scrubbed link on otherNote")
        #expect(h.library.note(note.id)?.speaker("b")?.background == true)

        // Undo must restore Bob, Bob's sample, a's confirmed link to Bob, Carol's original 1 sample,
        // otherNote/y's scrubbed link to Bob, and b's foreground state.
        await h.voices.undoSpeakerChanges(snapshot, noteID: note.id)
        await h.library.settle()

        let restoredBob = try #require(h.voices.voice(bob.id))
        #expect(restoredBob.name == "Bob")
        #expect(restoredBob.samples.count == 1)
        #expect(restoredBob.samples.first?.noteID == note.id)
        #expect(restoredBob.samples.first?.print.speakerID == "a")
        #expect(h.voices.voice(carol.id)?.samples.count == 1)
        #expect(h.library.note(note.id)?.speaker("a")?.match == .confirmed(voice: bob.id, score: 1))
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Bob")
        #expect(h.library.note(note.id)?.speaker("b")?.background == false)
        #expect(h.library.note(otherNote.id)?.speaker("y")?.match == .auto(voice: bob.id, score: 0.9))
    }

    /// Multi-speaker swap (A -> Bob, B -> Carol, C -> background) followed by Undo replays inverse ops in strict
    /// reverse order so Bob is never temporarily deleted or overcounted.
    @Test func batchUndoReplaysMultiSpeakerSwapInStrictReverseOrder() async throws {
        defer { h.tearDown() }
        let printA = SpeakerPrint(speakerID: "a", model: VoiceprintModel.sha256, vector: [1, 0], speechSeconds: 10)
        let printB = SpeakerPrint(speakerID: "b", model: VoiceprintModel.sha256, vector: [0, 1], speechSeconds: 10)
        let printOther = SpeakerPrint(speakerID: "x", model: VoiceprintModel.sha256, vector: [0.5, 0.5], speechSeconds: 10)

        var note = Note(title: "Swap")
        note.status = .ready
        note.speakers = [
            NoteSpeaker(id: "a", name: "Speaker 1"),
            NoteSpeaker(id: "b", name: "Speaker 2"),
            NoteSpeaker(id: "c", name: "Speaker 3"),
        ]
        note.transcript = [
            .init(text: "One", start: 0, end: 5, speaker: "Speaker 1", speakerID: "a"),
            .init(text: "Two", start: 6, end: 11, speaker: "Speaker 2", speakerID: "b"),
            .init(text: "Three", start: 12, end: 15, speaker: "Speaker 3", speakerID: "c"),
        ]
        var otherNote = Note(title: "CarolNote")
        otherNote.status = .ready
        otherNote.speakers = [NoteSpeaker(id: "x", name: "Speaker 1")]
        otherNote.transcript = [.init(text: "Hi", start: 0, end: 5, speaker: "Speaker 1", speakerID: "x")]
        let repo = try NoteRepository(root: h.root)
        try repo.save(note)
        try repo.save(otherNote)
        await h.start()
        try await h.voices.store?.savePrints([printA, printB], noteID: note.id)
        try await h.voices.store?.savePrints([printOther], noteID: otherNote.id)

        try await remember("Bob", speaker: "b", in: note.id, voices: h.voices)
        try await remember("Carol", speaker: "x", in: otherNote.id, voices: h.voices)
        let bob = try #require(h.voices.savedVoices.first { $0.name == "Bob" })
        let carol = try #require(h.voices.savedVoices.first { $0.name == "Carol" })

        let snapshot = try await h.voices.performBatch([
            .init(speakerID: "a", effects: [
                .relabel(speakerID: "a", name: "Bob"),
                .rememberVoice(speakerID: "a", voiceID: bob.id, name: "Bob"),
            ]),
            .init(speakerID: "b", effects: [
                .unenrol(speakerID: "b"),
                .relabel(speakerID: "b", name: "Carol"),
                .rememberVoice(speakerID: "b", voiceID: carol.id, name: "Carol"),
            ]),
            .init(speakerID: "c", effects: [.setBackground(speakerID: "c", background: true)]),
        ], noteID: note.id)
        await h.library.settle()

        #expect(h.voices.voice(bob.id)?.samples.map(\.print.speakerID) == ["a"])
        #expect(h.voices.voice(carol.id)?.samples.count == 2)
        #expect(h.library.note(note.id)?.speaker("c")?.background == true)

        await h.voices.undoSpeakerChanges(snapshot, noteID: note.id)
        await h.library.settle()

        let restoredBob = try #require(h.voices.voice(bob.id))
        #expect(restoredBob.samples.count == 1)
        #expect(restoredBob.samples.first?.print.speakerID == "b")
        #expect(h.voices.voice(carol.id)?.samples.count == 1)
        #expect(h.voices.voice(carol.id)?.samples.first?.noteID == otherNote.id)
        #expect(h.library.note(note.id)?.speaker("a")?.match == .unmatched)
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Speaker 1")
        #expect(h.library.note(note.id)?.speaker("b")?.match == .confirmed(voice: bob.id, score: 1))
        #expect(h.library.note(note.id)?.speaker("b")?.name == "Bob")
        #expect(h.library.note(note.id)?.speaker("c")?.background == false)
    }

    /// Renaming a saved voice in a batch alongside marking another speaker background is reversed by Undo.
    @Test func batchUndoReversesSavedVoiceRename() async throws {
        defer { h.tearDown() }
        var note = Note(title: "Rename")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript = [
            .init(text: "Hello", start: 0, end: 6, speaker: "Speaker 1", speakerID: "a"),
            .init(text: "Noise", start: 7, end: 10, speaker: "Speaker 2", speakerID: "b"),
        ]
        try NoteRepository(root: h.root).save(note)
        await h.start()
        try await h.voices.store?.savePrints([print], noteID: note.id)
        try await remember("Alex", speaker: "a", in: note.id, voices: h.voices)
        let alex = try #require(h.voices.savedVoices.first)

        let snapshot = try await h.voices.performBatch([
            .init(speakerID: "a", effects: [
                .relabel(speakerID: "a", name: "Alexander"),
                .renameVoice(alex.id, name: "Alexander"),
            ]),
            .init(speakerID: "b", effects: [.setBackground(speakerID: "b", background: true)]),
        ], noteID: note.id)
        await h.library.settle()

        #expect(h.voices.voice(alex.id)?.name == "Alexander")
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Alexander")
        #expect(h.library.note(note.id)?.speaker("b")?.background == true)

        await h.voices.undoSpeakerChanges(snapshot, noteID: note.id)
        await h.library.settle()

        #expect(h.voices.voice(alex.id)?.name == "Alex")
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Alex")
        #expect(h.library.note(note.id)?.speaker("b")?.background == false)
    }

    /// Switching transcript versions while the Undo snackbar is visible never overwrites the newly shown version;
    /// Undo restores only the original version's changed speakers.
    @Test func batchUndoAfterSwitchingTranscriptVersionsDoesNotCorruptCurrentVersion() async throws {
        defer { h.tearDown() }
        let v1 = UUID(), v2 = UUID()
        var note = Note(title: "Two versions")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "s1", name: "Silvio", provenance: .user),
                         NoteSpeaker(id: "s2", name: "Ruurd", provenance: .user)]
        note.transcript = [
            .init(text: "Hello", start: 0, end: 4, speaker: "Silvio", speakerID: "s1"),
            .init(text: "Coffee", start: 5, end: 8, speaker: "Ruurd", speakerID: "s2"),
        ]
        note.saveCurrentVersion(.transcription, id: v1)

        note.speakers = [NoteSpeaker(id: "s1", name: "Alice", provenance: .user),
                         NoteSpeaker(id: "s3", name: "Bob", provenance: .user, background: true)]
        note.transcript = [
            .init(text: "Different", start: 0, end: 4, speaker: "Alice", speakerID: "s1"),
            .init(text: "Chatter", start: 5, end: 8, speaker: "Bob", speakerID: "s3"),
        ]
        note.saveCurrentVersion(.speakerAnalysis, id: v2)
        note.selectVersion(v1)
        try NoteRepository(root: h.root).save(note)
        await h.start()

        // Mark s2 as background on v1.
        let snapshot = try await h.voices.performBatch([
            .init(speakerID: "s2", effects: [.setBackground(speakerID: "s2", background: true)]),
        ], noteID: note.id)
        #expect(snapshot.versionID == v1)
        #expect(h.library.note(note.id)?.speaker("s2")?.background == true)

        // Switch to v2 while the Undo snackbar is still available.
        h.voices.selectTranscriptVersion(noteID: note.id, versionID: v2)
        await h.library.settle()
        #expect(h.library.note(note.id)?.selectedVersionID == v2)

        // Tap Undo: v2 must remain untouched, while v1's s2 is restored to foreground.
        await h.voices.undoSpeakerChanges(snapshot, noteID: note.id)
        await h.library.settle()

        let currentV2 = try #require(h.library.note(note.id))
        #expect(currentV2.selectedVersionID == v2)
        #expect(currentV2.speakers?.map(\.name) == ["Alice", "Bob"])
        #expect(currentV2.speaker("s3")?.background == true)

        h.voices.selectTranscriptVersion(noteID: note.id, versionID: v1)
        await h.library.settle()
        let restoredV1 = try #require(h.library.note(note.id))
        #expect(restoredV1.speaker("s1")?.name == "Silvio")
        #expect(restoredV1.speaker("s2")?.name == "Ruurd")
        #expect(restoredV1.speaker("s2")?.background == false)
    }

    /// A failure on the second speaker rolls back earlier speakers' note and voice writes cleanly so a subsequent retry
    /// commits the complete batch and Undo restores the full original state.
    @Test func batchFailureOnSecondSpeakerRollsBackForCleanRetryAndUndo() async throws {
        defer { h.tearDown() }
        var note = Note(title: "Batch failure")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript = [
            .init(text: "Hello", start: 0, end: 6, speaker: "Speaker 1", speakerID: "a"),
            .init(text: "Noise", start: 7, end: 10, speaker: "Speaker 2", speakerID: "b"),
        ]
        try NoteRepository(root: h.root).save(note)
        await h.start()
        try await h.voices.store?.savePrints([print], noteID: note.id)

        // 1. Upfront validation refuses before writing speaker a if speaker b lacks a print.
        do throws(VoicesStore.SaveFailure) {
            _ = try await h.voices.performBatch([
                .init(speakerID: "a", effects: [
                    .relabel(speakerID: "a", name: "Alex"),
                    .rememberVoice(speakerID: "a", voiceID: nil, name: "Alex"),
                ]),
                .init(speakerID: "b", effects: [
                    .relabel(speakerID: "b", name: "Bea"),
                    .rememberVoice(speakerID: "b", voiceID: nil, name: "Bea"),
                ]),
            ], noteID: note.id)
            Issue.record("expected tooLittleSpeech refusal")
        } catch {
            guard case .tooLittleSpeech = error.reason else { Issue.record("\(error.reason)"); return }
        }
        #expect(h.voices.savedVoices.isEmpty)
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Speaker 1")

        // 2. Inject a failure on the second speaker after speaker a has written to both NoteStore and VoiceStore.
        let writes: [SpeakerSheetSession.BatchWrite] = [
            .init(speakerID: "a", effects: [
                .relabel(speakerID: "a", name: "Alex"),
                .rememberVoice(speakerID: "a", voiceID: nil, name: "Alex"),
            ]),
            .init(speakerID: "b", effects: [.setBackground(speakerID: "b", background: true)]),
        ]
        h.voices.beforeBatchStep = { stepIndex, _ throws(VoicesStore.SaveFailure) in
            if stepIndex == 1 { throw VoicesStore.SaveFailure(reason: .noteNotSaved) }
        }
        do throws(VoicesStore.SaveFailure) {
            _ = try await h.voices.performBatch(writes, noteID: note.id)
            Issue.record("expected injected noteNotSaved on step 1")
        } catch {
            guard case .noteNotSaved = error.reason else { Issue.record("\(error.reason)"); return }
        }
        await h.library.settle()

        // Rollback must have removed Alex from VoiceStore and restored Speaker 1 on disk.
        #expect(h.voices.savedVoices.isEmpty)
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Speaker 1")
        #expect(h.library.note(note.id)?.speaker("a")?.match == .unmatched)
        #expect(h.library.note(note.id)?.speaker("b")?.background == false)
        let storedAfterRollback = try #require(try h.stored(note.id))
        #expect(storedAfterRollback.speaker("a")?.name == "Speaker 1")

        // 3. Retry succeeds and produces a complete Undo snapshot that reverts both speakers cleanly.
        h.voices.beforeBatchStep = nil
        let snapshot = try await h.voices.performBatch(writes, noteID: note.id)
        await h.library.settle()
        #expect(h.voices.savedVoices.map(\.name) == ["Alex"])
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Alex")
        #expect(h.library.note(note.id)?.speaker("b")?.background == true)

        await h.voices.undoSpeakerChanges(snapshot, noteID: note.id)
        await h.library.settle()
        #expect(h.voices.savedVoices.isEmpty)
        #expect(h.library.note(note.id)?.speaker("a")?.name == "Speaker 1")
        #expect(h.library.note(note.id)?.speaker("a")?.match == .unmatched)
        #expect(h.library.note(note.id)?.speaker("b")?.background == false)
    }
}
