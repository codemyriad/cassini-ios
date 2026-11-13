import Foundation
import Testing
@testable import CassiniNotebook

/// Android's SavedVoicesViewModelTest over the pure screen state. The options menu is a system menu on iOS, so its
/// open state is not kept (see docs/differences.md).
@Suite struct SavedVoicesScreenTests {
    typealias F = VoiceFixtures
    let giulia = F.voice("g", "Giulia", seconds: 1_320)
    let luca = F.voice("l", "Luca", seconds: 30)

    func people(_ voices: [SavedVoice]? = nil, notes: [Note] = []) -> [SavedVoiceSummary] {
        SavedVoiceList.summaries(voices ?? [giulia, luca], notes: notes, model: F.model)
    }

    func note(linking voices: [UUID], trashed: Bool = false) -> Note {
        var note = Note(title: "Call")
        note.speakers = voices.enumerated().map { NoteSpeaker(id: "s\($0.offset)", name: "x", match: .confirmed(voice: $0.element, score: 1)) }
        if trashed { note.trashedAt = .now }
        return note
    }

    // ports: SavedVoicesViewModelTest#listsThePeopleInTheRepositoryOrderWithTheirCountsAndStaleFlag
    @Test func listsThePeopleWithTheirCountsAndStaleFlag() {
        let stale = F.voice("o", "Olga", seconds: 30, model: "old")
        let list = people([luca, stale, giulia], notes: [note(linking: [giulia.id]), note(linking: [giulia.id, luca.id]),
                                                        note(linking: [luca.id], trashed: true)])
        #expect(list.map(\.name) == ["Giulia", "Luca", "Olga"])
        #expect(list.map(\.notes) == [2, 1, 0])
        #expect(list.map(\.stale) == [false, false, true])
        #expect(list.first?.confirmedSeconds == 1_320)
        #expect(SavedVoicesScreen().dialog(people: list, readOnly: false) == nil)
    }

    // ports: VoiceRepositoryTest#savedVoicesAreSortedAndMarkedStale
    @Test func savedVoicesAreSortedAndMarkedStale() {
        let lucaLong = F.voice("luca", "Luca", seconds: 500), anna = F.voice("anna", "Anna", seconds: 20)
        let old = F.voice("old", "Old model", seconds: 900, model: "another-model")
        let short = F.voice("short", "Short print", F.axis(0, dimension: 4), seconds: 600)
        var linked = note(linking: [anna.id])
        linked.speakers?[0].match = .auto(voice: anna.id, score: 0.9)
        let list = SavedVoiceList.summaries([lucaLong, anna, old, short], notes: [linked], model: F.model)
        #expect(list.map(\.name) == ["Anna", "Old model", "Short print", "Luca"])
        #expect(list.map(\.notes) == [1, 0, 0, 0])
        #expect(list.map(\.stale) == [false, true, false, false], "iOS staleness is by model; a dimension is per sample")
        #expect(list.first?.confirmedSeconds == 20)
    }

    @Test func coloursFollowSaveOrderThroughNameCountAndSampleSortChanges() {
        var alex = F.voice("alex", "Alex", seconds: 60).saved(at: 7)
        let ben = F.voice("ben", "Ben", seconds: 120).saved(at: 12)
        let before = people([alex, ben])
        #expect(before.map(\.name) == ["Ben", "Alex"])
        #expect(before.map(\.colourIndex) == [12, 7])
        alex.name = "Zoe"
        alex.samples.append(VoiceSample(noteID: UUID(), print: F.print(F.axis(1))))
        let after = people([ben, alex], notes: [note(linking: [alex.id])])
        #expect(after.map(\.name) == ["Zoe", "Ben"])
        #expect(after.map(\.saveSequence) == [7, 12])
        #expect(Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.colourIndex) }) ==
                Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.colourIndex) }))
        let legacy = people([luca, giulia])
        #expect(legacy.map(\.name) == ["Giulia", "Luca"])
        #expect(legacy.map(\.colourIndex) == [1, 0], "migrate append order before applying the screen sort")
    }

    // ports: SavedVoicesViewModelTest#renameFromTheOptionsMenu
    @Test func renameFromTheOptionsMenu() {
        var screen = SavedVoicesScreen()
        #expect(screen.reduce(.rename(giulia.id), readOnly: false) == nil)
        #expect(screen.dialog(people: people(), readOnly: false) == .rename(giulia.id, name: "Giulia"))
        #expect(screen.reduce(.renameConfirmed(giulia.id, name: "Giulia R."), readOnly: false) == .rename(giulia.id, name: "Giulia R."))
        #expect(screen.dialog(people: people(), readOnly: false) == nil)
    }

    // ports: SavedVoicesViewModelTest#forgetAndForgetEveryoneAskFirst
    @Test func forgetAndForgetEveryoneAskFirst() {
        var screen = SavedVoicesScreen()
        _ = screen.reduce(.forget(luca.id), readOnly: false)
        #expect(screen.dialog(people: people(), readOnly: false) == .forget(luca.id, name: "Luca"))
        #expect(screen.reduce(.dismissDialog, readOnly: false) == nil)
        #expect(screen.dialog == nil)

        _ = screen.reduce(.forget(luca.id), readOnly: false)
        #expect(screen.reduce(.confirmDialog, readOnly: false) == .forget(luca.id))

        _ = screen.reduce(.forgetEveryone, readOnly: false)
        #expect(screen.dialog(people: people(), readOnly: false) == .forgetEveryone(count: 2))
        #expect(screen.reduce(.confirmDialog, readOnly: false) == .forgetEveryone)
        #expect(screen.dialog(people: people(), readOnly: false) == nil)
    }

    // ports: SavedVoicesViewModelTest#theOpenDialogSurvivesProcessDeath
    @Test func theOpenDialogSurvivesARelaunch() {
        var screen = SavedVoicesScreen()
        _ = screen.reduce(.forget(giulia.id), readOnly: false)
        let restored = SavedVoicesScreen(dialog: screen.dialog)
        #expect(restored.dialog(people: people(), readOnly: false) == .forget(giulia.id, name: "Giulia"))
        // A dialog for someone no longer in the list closes.
        #expect(restored.dialog(people: people([luca]), readOnly: false) == nil)
        #expect(SavedVoicesScreen(dialog: "everyone").dialog(people: [], readOnly: false) == nil)
    }

    // ports: SavedVoicesViewModelTest#aListThatCannotBeUsedIsReadOnlyAndIgnoresEdits
    @Test func aListThatCannotBeUsedIsReadOnlyAndIgnoresEdits() {
        var screen = SavedVoicesScreen()
        let actions = [SavedVoicesEvent.forget(giulia.id), .forgetEveryone, .confirmDialog, .renameConfirmed(giulia.id, name: "X")]
            .compactMap { screen.reduce($0, readOnly: true) }
        #expect(actions.isEmpty)
        #expect(screen.dialog == nil)
        #expect(SavedVoicesScreen(dialog: "everyone").dialog(people: people(), readOnly: true) == nil)
    }

    @Test func confirmedSpeechReadsInWholeMinutes() {
        #expect(SavedVoiceList.roughMinutes(59.9) == nil)
        #expect(SavedVoiceList.roughMinutes(60) == 1)
        #expect(SavedVoiceList.roughMinutes(22 * 60 + 59) == 22)
    }
}
