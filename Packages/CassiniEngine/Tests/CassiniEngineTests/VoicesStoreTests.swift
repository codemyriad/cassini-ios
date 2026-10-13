import Foundation
import Testing
import CassiniEngine
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
    let print = SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 10)
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
        try await voices.store?.savePrints([SpeakerPrint(speakerID: "a", model: "test", vector: [0, 1], speechSeconds: 10)],
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
}
