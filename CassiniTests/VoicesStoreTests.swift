import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// Naming, saved voices and speaker analysis through the app graph: the note and the voice files together.
@MainActor final class VoicesStoreTests: XCTestCase {
    private let print = SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 10)

    /// A note whose speaker "a" says two passages, with its print on disk.
    private func namedNote(in test: TestGraph, print: SpeakerPrint? = nil) async throws -> Note {
        var note = Note(title: "Speaker session")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"),
                           .init(text: "Again", start: 9, end: 12, speaker: "Speaker 1", speakerID: "a")]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        try await test.graph.voices.store?.savePrints([print ?? self.print], noteID: note.id)
        return note
    }

    private func remember(_ name: String, speaker: String = "a", in note: UUID, voices: VoicesStore) async throws(VoicesStore.SaveFailure) {
        try await voices.perform([.relabel(speakerID: speaker, name: name), .rememberVoice(speakerID: speaker, voiceID: nil, name: name)],
                                 noteID: note, speakerID: speaker)
    }

    /// Android semantics: renaming a saved voice keeps the names already in notes; forgetting keeps them too.
    func testNamingPersistsAndRenameOrForgetKeepTheNamesInNotes() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        try await remember("Alex", in: note.id, voices: test.graph.voices)
        XCTAssertEqual(test.graph.library.note(note.id)?.transcript.map(\.speaker), ["Alex", "Alex"])
        await test.graph.library.settle()

        let second = test.reopened()
        await second.graph.start()
        let voices = second.graph.voices, library = second.graph.library
        let voice = try XCTUnwrap(voices.savedVoices.first)
        XCTAssertEqual(library.note(note.id)?.speakers?.first?.match, .confirmed(voice: voice.id, score: 1))
        XCTAssertEqual(voices.summaries.first?.notes, 1)

        let renamed = await voices.rename(voice.id, name: "Alice")
        XCTAssertEqual(renamed, .done)
        XCTAssertEqual(voices.savedVoices.first?.name, "Alice")
        XCTAssertEqual(library.note(note.id)?.transcript.map(\.speaker), ["Alex", "Alex"], "names already in notes stay")

        let forgotten = await voices.forget(voice.id)
        XCTAssertEqual(forgotten, .done)
        XCTAssertTrue(voices.savedVoices.isEmpty)
        XCTAssertEqual(library.note(note.id)?.speakers?.first?.match, .unmatched)
        XCTAssertEqual(library.note(note.id)?.transcript.first?.speaker, "Alex")
    }

    func testForgetEveryoneAdvancesTheGenerationAndDeletesEveryPrint() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        let voices = test.graph.voices
        try await remember("Alex", in: note.id, voices: voices)
        let generation = test.graph.settings.voicesGeneration
        let outcome = await voices.forgetEveryone()
        XCTAssertEqual(outcome, .done)
        XCTAssertGreaterThan(test.graph.settings.voicesGeneration, generation)
        XCTAssertTrue(voices.savedVoices.isEmpty)
        XCTAssertFalse(voices.hasEvidence)
        let prints = try await voices.store?.prints(noteID: note.id)
        XCTAssertEqual(prints, [])
        XCTAssertEqual(test.graph.library.note(note.id)?.speakers?.first?.match, .unmatched)
    }

    /// An analysis that began before Forget everyone keeps no voiceprints, even though it finishes after it.
    func testASpeakerAnalysisThatStartedBeforeForgetEveryoneKeepsNoVoiceprints() async throws {
        let late = SpeakerAnalysis(turns: [.init(speakerID: "late", start: 0, end: 12)],
                                   prints: [.init(speakerID: "late", model: "test", vector: [1, 0], speechSeconds: 12)])
        let analyzer = FakeAnalyzer(analysis: late, suspends: true)
        let test = TestGraph(analyzer: analyzer); defer { test.tearDown() }
        var note = Note(title: "Conversation", audioFilename: "audio.caf")
        note.status = .ready
        note.transcript = [.init(text: "Hello", start: 0, end: 12)]
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        let graph = test.graph
        graph.settings.recordSpeakerConsent()

        let outcome = await graph.processing.transcribe(note.id, kind: .speakersOnly)
        XCTAssertEqual(outcome, .queued(changed: true))
        await waitUntil { analyzer.analyzeCount == 1 }
        _ = await graph.voices.forgetEveryone()
        analyzer.resume()
        await graph.processing.coordinator?.awaitIdle()
        await graph.library.settle()

        XCTAssertEqual(graph.library.note(note.id)?.speakers?.count, 1, "the speakers are still told apart")
        let prints = try await graph.voices.store?.prints(noteID: note.id)
        XCTAssertEqual(prints, [])
    }

    func testVoiceSuggestionsAutoNamingAndTrashedEvidence() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var source = Note(title: "Known person")
        source.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        source.transcript = [.init(text: "Reference", start: 0, end: 10, speaker: "Alex", speakerID: "a")]
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10)]
        try repository.save(source); try repository.save(target)
        await test.graph.start()
        let voices = test.graph.voices, library = test.graph.library, settings = test.graph.settings
        try await voices.store?.savePrints([print], noteID: source.id)
        try await voices.perform([.rememberVoice(speakerID: "a", voiceID: nil, name: "Alex")], noteID: source.id, speakerID: "a")
        let voiceID = try XCTUnwrap(voices.savedVoices.first?.id)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print])
        let generation = settings.voicesGeneration
        settings.automaticallyNameVoices = false
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        XCTAssertEqual(library.note(target.id)?.speakers?.first?.suggestedVoiceID, voiceID)
        XCTAssertNil(library.note(target.id)?.speakers?.first?.linkedVoiceID)
        XCTAssertEqual(voices.suggestions(for: try XCTUnwrap(library.note(target.id))).first?.voiceName, "Alex")
        settings.automaticallyNameVoices = true
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        XCTAssertEqual(library.note(target.id)?.transcript.first?.speaker, "Alex")
        XCTAssertEqual(library.note(target.id)?.speakers?.first?.linkedVoiceID, voiceID)
        XCTAssertEqual(voices.savedVoices.first?.samples.count, 1, "An automatic match must not enrol new evidence")
        await test.graph.trash.moveToTrash(source.id)
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        XCTAssertNil(library.note(target.id)?.speakers?.first?.suggestedVoiceID)
        XCTAssertNil(library.note(target.id)?.speakers?.first?.linkedVoiceID)
    }

    /// Acceptance: "Yes, Alex" names the speaker and remembers its print; "Not Alex" stays after Identify speakers.
    func testASuggestionIsAcceptedOrRejectedForGood() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let source = try await namedNote(in: test)
        let voices = test.graph.voices, library = test.graph.library
        try await remember("Alex", in: source.id, voices: voices)
        var target = Note(title: "New conversation")
        target.transcript = [.init(text: "New speech", start: 0, end: 10), .init(text: "More", start: 10, end: 20)]
        try await library.insert(target)
        let analysis = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10), .init(speakerID: "b", start: 10, end: 20)],
                                       prints: [print])
        let generation = test.graph.settings.voicesGeneration
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        let suggestion = try XCTUnwrap(voices.suggestions(for: try XCTUnwrap(library.note(target.id))).first)

        try await voices.reject(suggestion, noteID: target.id)
        XCTAssertTrue(voices.suggestions(for: try XCTUnwrap(library.note(target.id))).isEmpty)
        try await voices.applySpeakerAnalysis(analysis, to: target.id, generation: generation)
        let again = try XCTUnwrap(library.note(target.id)?.speakers?.first)
        XCTAssertEqual(again.match, .unmatched, "a rejected voice stays rejected after another analysis")
        XCTAssertEqual(again.excludedVoiceIDs, [suggestion.voiceID])

        // Another note: Yes names and confirms.
        var other = Note(title: "Third")
        other.transcript = [.init(text: "Hi", start: 0, end: 10)]
        try await library.insert(other)
        try await voices.applySpeakerAnalysis(SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 10)], prints: [print]),
                                              to: other.id, generation: generation)
        let yes = try XCTUnwrap(voices.suggestions(for: try XCTUnwrap(library.note(other.id))).first)
        try await voices.accept(yes, noteID: other.id)
        XCTAssertEqual(library.note(other.id)?.transcript.first?.speaker, "Alex")
        XCTAssertEqual(library.note(other.id)?.speakers?.first?.match.voiceID, yes.voiceID)
        XCTAssertEqual(voices.savedVoices.first?.samples.count, 2)
    }

    /// Acceptance: a note save failure leaves no orphan voice.
    func testANoteThatCannotBeSavedLeavesNoVoice() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        let directory = test.root.appendingPathComponent(note.id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        do throws(VoicesStore.SaveFailure) {
            try await remember("Alex", in: note.id, voices: test.graph.voices)
            XCTFail("the name was saved into a folder that can't be written")
        } catch {
            XCTAssertEqual(error.message, SpeakersCopy.noteNotSaved)
        }
        XCTAssertTrue(test.graph.voices.savedVoices.isEmpty)
        let stored = try await test.graph.voices.store?.voices()
        XCTAssertEqual(stored, [])
        XCTAssertEqual(test.graph.library.note(note.id)?.speakers?.first?.name, "Speaker 1")
    }

    /// Confirmed as someone else: the old sample is taken back; a voice left without samples is forgotten everywhere.
    func testKeepingTheSavedNameUnenrolsAndMakesANewVoice() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        let voices = test.graph.voices
        try await remember("Anna", in: note.id, voices: voices)
        let anna = try XCTUnwrap(voices.savedVoices.first)
        let opened = await voices.namingInput(noteID: note.id, speakerID: "a")
        let input = try XCTUnwrap(opened)
        var state = SpeakerNaming.open(input)
        state = try XCTUnwrap(SpeakerNaming.reduce(state, .nameChanged("Annette")).state)
        state = try XCTUnwrap(SpeakerNaming.reduce(state, .keepSaved).state)
        let effects = SpeakerNaming.reduce(state, .save).effects.filter { $0 != .close }
        try await voices.perform(effects, noteID: note.id, speakerID: "a")

        XCTAssertEqual(voices.savedVoices.map(\.name), ["Annette"])
        XCTAssertNotEqual(voices.savedVoices.first?.id, anna.id, "Anna had only this sample and is forgotten")
        XCTAssertEqual(test.graph.library.note(note.id)?.speakers?.first?.match.voiceID, voices.savedVoices.first?.id)
    }

    func testNamingASpeakerKeepsWhatAnEngineWriterSavedBeforeTheNameLanded() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Speaker session")
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a")]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        let library = test.graph.library, voices = test.graph.voices
        let noteStore = try XCTUnwrap(library.noteStore)

        let naming = Task { try await voices.perform([.relabel(speakerID: "a", name: "Alex")], noteID: note.id, speakerID: "a") }
        // A transcription job saves the note while the name is on its way to the store.
        try await noteStore.mutate(note.id) { $0.status = .ready; $0.title = "Retitled by a job" }
        try await naming.value
        await library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.title, "Retitled by a job")
        XCTAssertEqual(stored.status, .ready)
        XCTAssertEqual(stored.speakers?.map(\.name), ["Alex"])
        XCTAssertEqual(stored.transcript.map(\.speaker), ["Alex"])
        XCTAssertEqual(library.note(note.id), stored)
        XCTAssertNil(test.graph.errors.current)
    }

    func testASpeakerAnalysisKeepsWhatAnEngineWriterSavedBeforeItLanded() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Conversation")
        note.status = .ready
        note.transcript = [.init(text: "First", start: 0, end: 4), .init(text: "Second", start: 5, end: 9)]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        let library = test.graph.library, voices = test.graph.voices
        let noteStore = try XCTUnwrap(library.noteStore)
        let analysis = SpeakerAnalysis(
            turns: [.init(speakerID: "x", start: 0, end: 4.5), .init(speakerID: "y", start: 4.5, end: 9)], prints: [])

        let analyzing = Task { try await voices.applySpeakerAnalysis(analysis, to: note.id, generation: test.graph.settings.voicesGeneration) }
        // An engine writer saves the note while the analysis is on its way to the store.
        try await noteStore.mutate(note.id) { $0.isFavorite = true; $0.title = "Retitled by a job" }
        try await analyzing.value
        await library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.title, "Retitled by a job")
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.speakers?.map(\.name), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(stored.transcript.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(stored.versions?.map(\.name), ["Before speaker analysis", "Speaker analysis"])
        XCTAssertEqual(stored.selectedVersionID, stored.versions?.last?.id)
        XCTAssertEqual(library.note(note.id), stored)
        XCTAssertNil(test.graph.errors.current)
    }

    /// At launch, the voiceprints of notes that are gone are deleted.
    func testTheLaunchSweepsThePrintsOfNotesThatAreGone() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let gone = UUID()
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NoteVoiceCodec.encode([print]).write(to: folder.appendingPathComponent(NoteVoiceCodec.fileName(gone)))
        let report = await test.graph.start()
        XCTAssertTrue(report.ran.contains(.voiceLinks))
        XCTAssertNil(report.failed[.voiceLinks])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(NoteVoiceCodec.fileName(gone)).path))
    }

    /// A voices file from a newer Cassini: read-only, kept as it is, and permanent deletion waits.
    func testANewerVoicesFileIsReadOnly() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"voices":[]}"#.utf8).write(to: folder.appendingPathComponent("voices.json"))
        await test.graph.start()
        let voices = test.graph.voices
        XCTAssertTrue(voices.isReadOnly)
        let outcome = await voices.forgetEveryone()
        XCTAssertEqual(outcome, .readOnly)
        do {
            try await voices.removeEvidence(noteID: UUID())
            XCTFail("evidence removed while the voices are unreadable")
        } catch {}
    }

    /// A note whose note.json can't be read now keeps its folder, and so keeps its voiceprints through the sweep.
    func testTheLaunchSweepKeepsThePrintsOfNotesThatCouldNotBeRead() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let unreadable = UUID()
        let noteFolder = test.root.appendingPathComponent(unreadable.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: noteFolder, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":3}"#.utf8).write(to: noteFolder.appendingPathComponent(NoteRepository.metadataFilename))
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NoteVoiceCodec.encode([print]).write(to: folder.appendingPathComponent(NoteVoiceCodec.fileName(unreadable)))
        let report = await test.graph.start()
        XCTAssertTrue(report.ran.contains(.voiceLinks))
        XCTAssertEqual(test.graph.library.unreadableCount, 1)
        let prints = try await test.graph.voices.store?.prints(noteID: unreadable)
        XCTAssertEqual(prints, [print])
    }

    /// While the saved voices can't be read, the list is not known: opening another version keeps every link.
    func testSelectingAVersionWhileTheVoicesAreNewerKeepsTheLinks() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let alex = UUID()
        var note = Note(title: "Versions")
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "a", name: "Alex", match: .confirmed(voice: alex, score: 1))]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Alex", speakerID: "a")]
        let first = UUID()
        note.saveCurrentVersion(name: "First", id: first)
        note.transcript = [.init(text: "Hello again", start: 0, end: 8, speaker: "Alex", speakerID: "a")]
        note.saveCurrentVersion(name: "Second")
        try NoteRepository(root: test.root).save(note)
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"voices":[]}"#.utf8).write(to: folder.appendingPathComponent("voices.json"))
        await test.graph.start()
        XCTAssertTrue(test.graph.voices.isReadOnly)

        test.graph.voices.selectTranscriptVersion(noteID: note.id, versionID: first)
        await test.graph.library.settle()

        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.selectedVersionID, first)
        XCTAssertEqual(stored.speakers?.first?.match, .confirmed(voice: alex, score: 1))
        XCTAssertEqual(stored.versions?.map { $0.speakers.first?.match }, [.confirmed(voice: alex, score: 1), .confirmed(voice: alex, score: 1)])
    }

    /// Two names saved at once (two suggestion cards, say) both start from the same saved voices; both are kept.
    func testOverlappingNamesKeepBothVoices() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var notes: [Note] = []
        for title in ["One", "Two"] {
            var note = Note(title: title)
            note.status = .ready
            note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1")]
            note.transcript = [.init(text: "Hello", start: 0, end: 10, speaker: "Speaker 1", speakerID: "a")]
            try repository.save(note)
            notes.append(note)
        }
        await test.graph.start()
        let voices = test.graph.voices
        try await voices.store?.savePrints([print], noteID: notes[0].id)
        try await voices.store?.savePrints([SpeakerPrint(speakerID: "a", model: "test", vector: [0, 1], speechSeconds: 10)],
                                           noteID: notes[1].id)

        let luca = Task { try await self.remember("Luca", in: notes[0].id, voices: voices) }
        let sam = Task { try await self.remember("Sam", in: notes[1].id, voices: voices) }
        try await luca.value
        try await sam.value
        await test.graph.library.settle()

        let saved = await voices.store?.voices()
        let stored = try XCTUnwrap(saved)
        XCTAssertEqual(Set(stored.map(\.name)), ["Luca", "Sam"])
        for (note, name) in zip(notes, ["Luca", "Sam"]) {
            let voice = try XCTUnwrap(stored.first { $0.name == name })
            XCTAssertEqual(voice.samples.map(\.noteID), [note.id])
            XCTAssertEqual(test.graph.library.note(note.id)?.speakers?.first?.match.voiceID, voice.id)
        }
    }

    /// Acceptance: the note is written but the voices can't be; the note's links go back and the error is shown.
    func testAVoiceWriteThatFailsPutsTheNotesLinksBack() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        let voices = test.graph.voices, library = test.graph.library
        try await remember("Alex", in: note.id, voices: voices)
        let alex = try XCTUnwrap(voices.savedVoices.first)
        library.update(note.id) { $0.saveCurrentVersion(name: "Named") }
        await library.settle()
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        do throws(VoicesStore.SaveFailure) {
            // "Not Alex" on Alex's only sample would forget Alex everywhere.
            try await voices.perform([.reject(speakerID: "a", voiceID: alex.id, voiceName: "Alex", unenrol: true, restorePlaceholder: false)],
                                     noteID: note.id, speakerID: "a")
            XCTFail("the voices were written into a folder that can't be written")
        } catch {
            XCTAssertNotEqual(error.message, SpeakersCopy.noteNotSaved)
            XCTAssertTrue(error.message.contains("could not be written"), error.message)
        }
        await library.settle()
        let stored = try XCTUnwrap(NoteRepository(root: test.root).load().notes.first { $0.id == note.id })
        XCTAssertEqual(stored.speakers?.first?.match, .confirmed(voice: alex.id, score: 1))
        XCTAssertEqual(stored.speakers?.first?.excludedVoiceIDs, [])
        XCTAssertEqual(stored.versions?.last?.speakers.first?.match, .confirmed(voice: alex.id, score: 1))
        XCTAssertEqual(voices.savedVoices, [alex])
    }

    /// Deleting a note for good takes its samples; a voice left with none is forgotten and unlinked everywhere.
    func testRemovingTheOnlyEvidenceOfAVoiceForgetsIt() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        let voices = test.graph.voices
        try await remember("Alex", in: note.id, voices: voices)
        try await voices.removeEvidence(noteID: note.id)
        XCTAssertTrue(voices.savedVoices.isEmpty)
        XCTAssertEqual(test.graph.library.note(note.id)?.speakers?.first?.match, .unmatched)
        XCTAssertEqual(test.graph.library.note(note.id)?.speakers?.first?.name, "Alex")
    }

    /// A damaged list with no voiceprints left: Forget all voice data is still offered and starts the list again.
    func testADamagedListWithoutPrintsCanStillBeForgotten() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent("voices.json"))
        await test.graph.start()
        let voices = test.graph.voices
        XCTAssertEqual(voices.snapshot.problem, .damaged)
        XCTAssertFalse(voices.hasEvidence)
        XCTAssertTrue(voices.offersForgetAllData)
        let outcome = await voices.forgetEveryone()
        XCTAssertEqual(outcome, .done)
        XCTAssertFalse(voices.isReadOnly)
        XCTAssertFalse(voices.offersForgetAllData)
    }

    /// A Forget everyone that could not delete everything keeps the notes' links to the voices it kept.
    func testAForgetEveryoneThatFailsKeepsTheLinks() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = try await namedNote(in: test)
        let voices = test.graph.voices
        try await remember("Alex", in: note.id, voices: voices)
        let folder = test.root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let outcome = await voices.forgetEveryone()
        guard case .failed = outcome else { return XCTFail("forgot everyone in a folder that can't be written: \(outcome)") }
        XCTAssertEqual(voices.savedVoices.count, 1)
        XCTAssertNotNil(test.graph.library.note(note.id)?.speakers?.first?.match.voiceID)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
