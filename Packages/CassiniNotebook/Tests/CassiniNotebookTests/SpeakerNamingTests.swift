import Foundation
import Testing
@testable import CassiniNotebook

/// The Name a speaker reducer: every question path, the Save rule, "Not X" and merges. Android's draft cases are not
/// ported: iOS names speakers only after the analysis (see docs/differences/WP8.md).
@Suite struct SpeakerNamingTests {
    typealias F = VoiceFixtures
    let anna = F.voice("anna", "Anna Ricci", F.axis(0))
    let luca = F.voice("luca", "Luca Bianchi", F.axis(1))
    let elodie = F.voice("elodie", "Élodie Martin", F.axis(2))
    let paolo = [MergeTarget(speakerID: "s1", name: "Paolo", ordinal: 0, speakingTime: 9)]

    func input(label: String = "Speaker 3", match: VoiceMatchState = .unmatched, print: [Float]? = F.axis(0),
               seconds: Double = 12, voices: [SavedVoice]? = nil, modelReady: Bool = true,
               targets: [MergeTarget]? = nil) -> NamingInput {
        NamingInput(speakerID: "s3", label: label, ordinal: 2, speakingTime: 192,
                    sample: SampleWindow(start: 10, end: 20), print: print.map { F.print("s3", $0, seconds: seconds) },
                    match: match, voices: voices ?? [anna, luca, elodie], voiceModelReady: modelReady,
                    mergeTargets: targets ?? paolo, versions: MergeVersions(shown: 1, added: 2))
    }

    func on(_ state: NamingState, _ events: NamingEvent...) throws -> NamingState {
        try events.reduce(state) { state, event in try #require(SpeakerNaming.reduce(state, event).state, "closed on \(event)") }
    }

    func effects(_ state: NamingState, _ event: NamingEvent) -> [NamingEffect] { SpeakerNaming.reduce(state, event).effects }

    // ports: SpeakerNamingTest#aPlaceholderOpensEmptyWithRememberOnAndNothingToSave
    @Test func aPlaceholderOpensEmptyWithRememberOnAndNothingToSave() {
        let ui = SpeakerNaming.ui(SpeakerNaming.open(input()))
        #expect(ui.name == "")
        #expect(ui.remember)
        #expect(ui.rememberEnabled)
        #expect(ui.save == .disabled)
        #expect(ui.ranked)
        #expect(ui.voices.map(\.id) == [anna.id, elodie.id, luca.id])
        #expect(ui.voices.first?.likely == true, "the top voice scores 1.0 ≥ 0.65")
        #expect(ui.voices[1].likely == false)
        #expect(ui.placeholderNumber == 3)
    }

    // ports: SpeakerNamingTest#aTypedFirstNameAsksAboutTheSamePersonAndBlocksSave
    @Test func aTypedFirstNameAsksAboutTheSamePersonAndBlocksSave() throws {
        let state = try on(SpeakerNaming.open(input()), .nameChanged("anna"))
        let ui = SpeakerNaming.ui(state)
        #expect(ui.samePerson == "Anna Ricci")
        #expect(ui.save == .blockedByQuestion)
        let result = SpeakerNaming.reduce(state, .save)
        #expect(result.state == state, "Save stays open and moves focus to the question")
        #expect(result.effects == [.focusQuestion])
    }

    // ports: SpeakerNamingTest#accentsAndCaseDoNotMatterForTheSamePersonQuestion
    @Test func accentsAndCaseDoNotMatterForTheSamePersonQuestion() throws {
        let state = try on(SpeakerNaming.open(input()), .nameChanged("  ELODIE "))
        #expect(SpeakerNaming.ui(state).samePerson == "Élodie Martin")
    }

    // ports: SpeakerNamingTest#samePersonBindsTheVoiceAndSaveEnrolsIntoIt
    @Test func samePersonBindsTheVoiceAndSaveEnrolsIntoIt() throws {
        let state = try on(SpeakerNaming.open(input()), .nameChanged("Anna"), .samePerson)
        let ui = SpeakerNaming.ui(state)
        #expect(ui.name == "Anna Ricci")
        #expect(ui.samePerson == nil)
        #expect(ui.save == .enabled)
        #expect(effects(state, .save) == [.relabel(speakerID: "s3", name: "Anna Ricci"),
                                          .rememberVoice(speakerID: "s3", voiceID: anna.id, name: "Anna Ricci"), .close])
    }

    // ports: SpeakerNamingTest#someoneElseKeepsTheTypedNameAndMakesANewVoice
    @Test func someoneElseKeepsTheTypedNameAndMakesANewVoice() throws {
        let state = try on(SpeakerNaming.open(input()), .nameChanged("Anna"), .someoneElse)
        #expect(SpeakerNaming.ui(state).samePerson == nil)
        #expect(SpeakerNaming.ui(state).save == .enabled)
        #expect(effects(state, .save) == [.relabel(speakerID: "s3", name: "Anna"),
                                          .rememberVoice(speakerID: "s3", voiceID: nil, name: "Anna"), .close])
    }

    // ports: SpeakerNamingTest#withRememberOffThereIsNoQuestionAndOnlyTheLabelIsWritten
    @Test func withRememberOffThereIsNoQuestionAndOnlyTheLabelIsWritten() throws {
        let state = try on(SpeakerNaming.open(input()), .rememberToggled(false), .nameChanged("Anna"))
        #expect(SpeakerNaming.ui(state).samePerson == nil)
        #expect(effects(state, .save) == [.relabel(speakerID: "s3", name: "Anna"), .close])
    }

    // ports: SpeakerNamingTest#withoutAPrintTheListIsByNameAndThereIsNoQuestion
    @Test func withoutAPrintTheListIsByNameAndThereIsNoQuestion() throws {
        let state = try on(SpeakerNaming.open(input(print: nil)), .nameChanged("Anna"))
        let ui = SpeakerNaming.ui(state)
        #expect(!ui.ranked)
        #expect(ui.voices.map(\.id) == [anna.id, elodie.id, luca.id])
        #expect(ui.voices.allSatisfy { !$0.likely })
        #expect(ui.samePerson == nil)
        #expect(!ui.rememberEnabled)
        #expect(ui.rememberReason == .tooLittleSpeech)
    }

    // ports: SpeakerNamingTest#rememberIsDisabledWithTooLittleSpeechOrWithoutTheModel
    @Test func rememberIsDisabledWithTooLittleSpeechOrWithoutTheModel() {
        #expect(SpeakerNaming.ui(SpeakerNaming.open(input(seconds: 5))).rememberReason == .tooLittleSpeech)
        let noModel = SpeakerNaming.ui(SpeakerNaming.open(input(modelReady: false)))
        #expect(noModel.rememberReason == .noModel)
        #expect(!noModel.remember)
    }

    // ports: SpeakerNamingTest#pickingAVoiceBindsItAndEditingTheNameAwayUnbindsIt
    @Test func pickingAVoiceBindsItAndEditingTheNameAwayUnbindsIt() throws {
        let picked = try on(SpeakerNaming.open(input()), .pickVoice(luca.id))
        #expect(picked.name == "Luca Bianchi")
        #expect(picked.boundVoiceID == luca.id)
        #expect(try on(picked, .nameChanged("Luca B.")).boundVoiceID == nil)
        #expect(try on(picked, .nameChanged("luca bianchi")).boundVoiceID == luca.id, "the same name, written otherwise")
    }

    // ports: SpeakerNamingTest#showAllListsEveryVoiceAfterTheFirstThree
    @Test func showAllListsEveryVoiceAfterTheFirstThree() throws {
        let many = [anna, luca, elodie, F.voice("m", "Marco", F.axis(3)), F.voice("g", "Giulia", F.axis(4))]
        let state = SpeakerNaming.open(input(voices: many))
        #expect(SpeakerNaming.ui(state).voices.count == 3)
        #expect(SpeakerNaming.ui(state).showAll)
        let all = SpeakerNaming.ui(try on(state, .showAll))
        #expect(all.voices.count == 5)
        #expect(!all.showAll)
    }

    // ports: SpeakerNamingTest#aConfirmedVoiceIsBoundAtOpenAndUnchangedMeansNothingToSave
    @Test func aConfirmedVoiceIsBoundAtOpenAndUnchangedMeansNothingToSave() {
        let state = SpeakerNaming.open(input(label: "Anna Ricci", match: .confirmed(voice: anna.id, score: 0.8)))
        #expect(state.boundVoiceID == anna.id)
        #expect(SpeakerNaming.ui(state).save == .disabled)
        #expect(SpeakerNaming.ui(state).notName == "Anna Ricci")
    }

    // ports: SpeakerNamingTest#renamingAConfirmedSpeakerAsksToRenameTheSavedVoice
    @Test func renamingAConfirmedSpeakerAsksToRenameTheSavedVoice() throws {
        let confirmed = input(label: "Anna Ricci", match: .confirmed(voice: anna.id, score: 0.8))
        let typed = try on(SpeakerNaming.open(confirmed), .nameChanged("Annette"))
        #expect(SpeakerNaming.ui(typed).renameSaved == "Anna Ricci")
        #expect(SpeakerNaming.ui(typed).save == .blockedByQuestion)

        let renamed = try on(typed, .renameSaved)
        #expect(SpeakerNaming.ui(renamed).renameSaved == nil)
        #expect(effects(renamed, .save) == [.relabel(speakerID: "s3", name: "Annette"), .renameVoice(anna.id, name: "Annette"), .close])

        let someoneElse = try on(typed, .keepSaved)
        #expect(effects(someoneElse, .save) == [.relabel(speakerID: "s3", name: "Annette"), .unenrol(speakerID: "s3"),
                                                .rememberVoice(speakerID: "s3", voiceID: nil, name: "Annette"), .close])
    }

    // ports: SpeakerNamingTest#anAutoMatchIsConfirmedBySaveAndClearedWhenTheNameChangesWithoutRemember
    @Test func anAutoMatchIsConfirmedBySaveAndClearedWhenTheNameChangesWithoutRemember() throws {
        let state = SpeakerNaming.open(input(label: "Luca Bianchi", match: .auto(voice: luca.id, score: 0.86)))
        #expect(SpeakerNaming.ui(state).save == .enabled, "Save is enabled: the match is only automatic")
        #expect(effects(state, .save) == [.rememberVoice(speakerID: "s3", voiceID: luca.id, name: "Luca Bianchi"), .close])
        let renamed = try on(state, .rememberToggled(false), .nameChanged("Marco"))
        #expect(effects(renamed, .save) == [.relabel(speakerID: "s3", name: "Marco"), .clearMatch(speakerID: "s3"), .close])
    }

    // ports: SpeakerNamingTest#notThisPersonRejectsAndReturnsTheLabelToThePlaceholder
    @Test func notThisPersonRejectsAndReturnsTheLabelToThePlaceholder() throws {
        let auto = SpeakerNaming.open(input(label: "Luca Bianchi", match: .auto(voice: luca.id, score: 0.86)))
        let result = SpeakerNaming.reduce(auto, .notThisPerson)
        #expect(result.state == nil)
        #expect(result.effects == [.reject(speakerID: "s3", voiceID: luca.id, voiceName: "Luca Bianchi", unenrol: false,
                                           restorePlaceholder: true), .close])
        let confirmed = SpeakerNaming.open(input(label: "Anna", match: .confirmed(voice: anna.id, score: 0.8)))
        guard case .reject(_, _, _, let unenrol, let restore) = try #require(SpeakerNaming.reduce(confirmed, .notThisPerson).effects.first)
        else { Issue.record("no rejection"); return }
        #expect(unenrol, "a confirmed match is unenrolled first")
        #expect(!restore, "the label is not the voice's name")
    }

    // ports: SpeakerNamingTest#noMatchMeansNoNotThisPersonButton
    @Test func noMatchMeansNoNotThisPersonButton() {
        let state = SpeakerNaming.open(input())
        #expect(SpeakerNaming.ui(state).notName == nil)
        #expect(SpeakerNaming.reduce(state, .notThisPerson).state == state)
    }

    // ports: SpeakerNamingTest#mergeAsksForConfirmationAndAddsAVersionOnASealedNote
    @Test func mergeAsksForConfirmationAndAddsAVersion() throws {
        let open = SpeakerNaming.open(input())
        #expect(SpeakerNaming.ui(open).canMerge)
        let list = try on(open, .mergeInto)
        let ui = try #require(SpeakerNaming.mergeUI(list))
        #expect(ui.confirm == nil)
        #expect((ui.shownVersion, ui.addedVersion) == (1, 2))
        let confirm = try on(list, .mergeTarget("s1"))
        #expect(SpeakerNaming.mergeUI(confirm)?.confirm?.speakerID == "s1")
        #expect(SpeakerNaming.mergeUI(try on(confirm, .cancelMerge))?.confirm == nil)
        #expect(SpeakerNaming.mergeUI(try on(confirm, .closeMerge)) == nil, "back to the Name sheet")
        #expect(effects(confirm, .confirmMerge) == [.merge(source: "s3", target: "s1"), .close])
        #expect(!SpeakerNaming.ui(SpeakerNaming.open(input(targets: []))).canMerge)
    }

    // ports: SpeakerNamingTest#theSamplePlaysOnlyWithAPlayer
    @Test func theSamplePlaysOnlyWithAPlayer() {
        let state = SpeakerNaming.open(input())
        #expect(effects(state, .playSample) == [.playRange(SampleWindow(start: 10, end: 20))])
        var silent = input()
        silent.canSample = false
        let noPlayer = SpeakerNaming.open(silent)
        #expect(effects(noPlayer, .playSample).isEmpty)
        #expect(!SpeakerNaming.ui(noPlayer).canSample)
    }

    // ports: SpeakerNamingTest#cancelCloses
    @Test func cancelCloses() {
        let result = SpeakerNaming.reduce(SpeakerNaming.open(input()), .cancel)
        #expect(result.state == nil)
        #expect(result.effects == [.close])
    }

    // ports: SpeakerNamingTest#theNameIsCutAt80Characters
    @Test func theNameIsCutAt80Characters() throws {
        let state = try on(SpeakerNaming.open(input()), .nameChanged(String(repeating: "x", count: 100)))
        #expect(state.name.count == SpeakerNaming.maxName)
        #expect(SpeakerNaming.maxName == 80)
    }

    /// The acceptance case of the plan: "Anna" typed against a saved "Anna Ricci" asks the same-person question.
    @Test func annaAgainstASavedAnnaRicciAsksTheSamePersonQuestion() throws {
        let state = try on(SpeakerNaming.open(input(voices: [anna])), .nameChanged("Anna"))
        #expect(SpeakerNaming.samePerson(state)?.id == anna.id)
    }

    /// Saved voices that cannot be changed: Remember is off and disabled, and no question is asked.
    @Test func readOnlyVoicesTurnRememberOff() throws {
        var readOnly = input()
        readOnly.voicesReadOnly = true
        let state = try on(SpeakerNaming.open(readOnly), .nameChanged("Anna"))
        let ui = SpeakerNaming.ui(state)
        #expect(!ui.remember && !ui.rememberEnabled)
        #expect(ui.samePerson == nil)
        #expect(effects(state, .save) == [.relabel(speakerID: "s3", name: "Anna"), .close])
    }
}
