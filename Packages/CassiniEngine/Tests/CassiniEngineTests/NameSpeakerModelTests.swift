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
