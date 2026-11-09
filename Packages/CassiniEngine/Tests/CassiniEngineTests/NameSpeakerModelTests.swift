import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Name a speaker's model over the Note screen's ports (Android `NoteViewModelTest`'s naming cases): the question
/// before Save, writes that land before the sheet closes, a failure that keeps it open, the draft typed before Cassini
/// was closed, and no write while a job is pending for the note.
@MainActor @Suite struct NameSpeakerModelTests {
    let fake: FakeNoteScreen
    let screen: NoteScreenModel
    let anna = SavedVoice(name: "Anna Ricci", samples: [VoiceSample(noteID: UUID(), print: SpeakerPrint(
        speakerID: "x", model: "m", vector: [0, 1], speechSeconds: 30))])
    /// What the sheet did: closed, focused the question, toggled a sample.
    let actions = Actions()

    @MainActor final class Actions {
        var all: [NameSpeakerModel.SheetAction] = []
        func record(_ action: NameSpeakerModel.SheetAction) { all.append(action) }
    }

    init() {
        var note = Note(title: "Weekly sync")
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript = [.init(text: "Hello", start: 0, end: 8, speaker: "Speaker 1", speakerID: "a"),
                           .init(text: "Yes", start: 8, end: 20, speaker: "Speaker 2", speakerID: "b")]
        fake = FakeNoteScreen(note: note)
        fake.namingInput = NamingInput(speakerID: "b", label: "Speaker 2", ordinal: 1, speakingTime: 12,
                                       print: SpeakerPrint(speakerID: "b", model: "m", vector: [1, 0], speechSeconds: 12),
                                       voices: [anna])
        screen = NoteScreenModel(noteID: note.id, ports: fake.ports)
    }

    func open(draft: String? = nil) async -> NameSpeakerModel {
        let model = screen.naming("b")
        await model.open(draft: draft) { [actions] in actions.record($0) }
        return model
    }

    func send(_ model: NameSpeakerModel, _ events: NamingEvent...) {
        for event in events { model.send(event) { [actions] in actions.record($0) } }
    }

    // ports: NoteViewModelTest#aDraftSpeakerIsNamedThroughTheDraftNames
    @Test func aDraftSpeakerIsNamedThroughTheDraftNames() async throws {
        fake.job = Job(noteID: screen.noteID, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date())
        fake.speakerModelsReady = true
        fake.runningDraft = DraftState(words: [DraftWord(speaker: "s1", startMs: 0, endMs: 5_000, text: "Lunga"),
                                               DraftWord(speaker: "s2", startMs: 5_000, endMs: 6_000, text: "frase")],
                                       tentativeFromMs: 6_000, namingOpen: true)
        screen.speakerTapped("s1")
        #expect(screen.sheet == .naming("s1", draft: nil), "the draft opens Name a speaker while the job runs")
        let model = screen.naming("s1")
        await model.open(draft: nil) { [actions] in actions.record($0) }
        let sheet = SpeakerNaming.ui(try #require(model.state))
        #expect(sheet.draft)
        #expect(!sheet.canSample, "a running job holds the audio: no sample plays")
        send(model, .nameChanged("Luca"), .save)
        await model.settle()
        #expect(fake.draftWrites == [[.draftName(speakerID: "s1", name: "Luca", voice: .new, confirm: false, score: 1)]])
        #expect(fake.namingWrites.isEmpty, "a draft never rewrites the note")
        #expect(fake.draftNames.labels == ["s1": "Luca"] && fake.draftNames.remembered == ["s1": .new])

        // Once the job closed naming to save the note, the screen says why.
        screen.sheet = nil
        fake.draftNamingOpen = false
        screen.speakerTapped("s1")
        #expect(screen.screen.dialog == .readOnly(.saving))
        #expect(screen.sheet == nil)
    }

    // ports: NoteViewModelTest#theNameSheetAsksAboutTheSamePersonThenEnrolsANewVoice
    @Test func theNameSheetAsksAboutTheSamePersonThenEnrolsANewVoice() async throws {
        let model = await open()
        let opened = SpeakerNaming.ui(try #require(model.state))
        #expect(opened.name == "" && opened.remember)

        send(model, .nameChanged("Anna"))
        let asking = SpeakerNaming.ui(try #require(model.state))
        #expect(asking.samePerson == "Anna Ricci")
        #expect(asking.save == .blockedByQuestion)
        send(model, .save)
        #expect(fake.namingWrites.isEmpty, "Save with the question open saves nothing")
        #expect(actions.all == [.focusQuestion])

        send(model, .someoneElse, .save)
        await model.settle()
        #expect(fake.namingWrites == [[.relabel(speakerID: "b", name: "Anna"),
                                       .rememberVoice(speakerID: "b", voiceID: nil, name: "Anna")]])
        #expect(actions.all.last == .close)
    }

    @Test func theSheetClosesOnlyOnceTheWritesLandAndTakesNoEventMeanwhile() async throws {
        let model = await open()
        fake.holdsNaming = true
        send(model, .nameChanged("Bruno"), .save)
        #expect(model.saving)
        send(model, .nameChanged("Carla"), .save)
        #expect(!actions.all.contains(.close), "still writing")
        fake.releaseNaming()
        await model.settle()
        #expect(!model.saving)
        #expect(fake.namingWrites.count == 1, "the events sent while saving were ignored")
        #expect(actions.all == [.close])
    }

    @Test func aFailedSaveKeepsTheSheetOpenWithItsAlert() async throws {
        let model = await open()
        fake.namingFailure = VoicesStore.SaveFailure(reason: .tooLittleSpeech)
        send(model, .nameChanged("Bruno"), .save)
        await model.settle()
        guard case .save(let failure)? = model.failure, case .tooLittleSpeech = failure.reason else {
            Issue.record("\(String(describing: model.failure))"); return
        }
        #expect(!actions.all.contains(.close))
        #expect(model.state != nil)
    }

    // ports: NoteViewModelTest#sheetsAndDialogsComeBackAfterProcessDeath (the name typed before)
    @Test func theNameTypedBeforeCassiniWasClosedComesBack() async throws {
        let model = await open(draft: "Bru")
        #expect(SpeakerNaming.ui(try #require(model.state)).name == "Bru")
    }

    /// A speakers-only job queued while the sheet is open: the analysis would put its own speakers over the name.
    @Test func noNameIsSavedWhileAJobIsPendingForTheNote() async throws {
        let model = await open()
        fake.job = Job(noteID: screen.noteID, seq: 1, kind: .speakersOnly, enqueuedAt: Date(timeIntervalSince1970: 0))
        send(model, .nameChanged("Bruno"), .save)
        await model.settle()
        #expect(fake.namingWrites.isEmpty)
        guard case .readOnly(.jobPending)? = model.failure else { Issue.record("\(String(describing: model.failure))"); return }
        #expect(!actions.all.contains(.close))

        fake.job = nil
        model.failure = nil
        send(model, .save)
        await model.settle()
        #expect(fake.namingWrites.count == 1, "once the job is gone the name saves")
    }
}

extension NameSpeakerModelTests {
    @Test func aChipOnlyDraftSpeakerCanBeNamedAndMergedWhileNamingIsOpen() async throws {
        let words = [DraftWord(speaker: "a", startMs: 0, endMs: 500, text: "Ready,"),
                     DraftWord(speaker: "b", startMs: 450, endMs: 650, text: "Yes."),
                     DraftWord(speaker: "a", startMs: 500, endMs: 1000, text: "now.")]
        fake.job = Job(noteID: screen.noteID, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date())
        fake.runningDraft = DraftState(words: words, tentativeFromMs: .max, namingOpen: true)
        let shown = try #require(screen.shownDraft)
        let transcript = NoteTranscripts.draft(shown.words, tentativeFromMs: nil, labels: shown.labels)
        #expect(transcript.turns.map(\.speakerID) == ["a"], "Speaker b is present only in a chip")
        #expect(transcript.turns[0].interjections.map(\.speakerID) == ["b"])
        screen.speakerTapped("b")
        #expect(screen.sheet == .naming("b", draft: nil))
        let ben = screen.naming("b")
        await ben.open(draft: nil) { [actions] in actions.record($0) }
        let input = try #require(ben.state?.input)
        #expect(input.draft && input.speakerID == "b" && input.ordinal == 1)
        #expect(input.mergeTargets.map(\.speakerID) == ["a"])
        let ada = screen.naming("a")
        await ada.open(draft: nil) { [actions] in actions.record($0) }
        #expect(ada.state?.input.mergeTargets.map(\.speakerID) == ["b"])
        screen.sheet = nil
        fake.draftNamingOpen = false
        screen.speakerTapped("b")
        #expect(screen.sheet == nil)
        #expect(screen.screen.dialog == .readOnly(.saving))
    }
}
