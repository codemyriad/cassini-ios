import Foundation
import Testing
import CassiniEngine

/// The stack rules the app's `Router` carries out: how the Library opens screens on a phone and in split view, how
/// notes are popped to and closed, what a note screen's session keeps, and what the scene keeps of the stack.
@Suite struct ScreenStackTests {
    let a = UUID(), b = UUID()

    @Test func theLibraryPushesOnPhonesAndReplacesTheDetailInSplitView() {
        var screens = ScreenStack()
        screens.show(.note(a))
        screens.show(.settings)
        #expect(screens.stack == [.library, .note(a), .settings])
        screens.isSplit = true
        screens.show(.note(b))
        #expect(screens.path == [.note(b)])
    }

    @Test func inSplitViewTheDetailsFirstScreenIsSelectedAndHasNoBackButton() {
        var screens = ScreenStack(path: [.note(a), .savedVoices])
        #expect(screens.selectedNoteID == nil, "a phone has no selection")
        #expect(!screens.hidesBackButton(.note(a)))
        screens.isSplit = true
        #expect(screens.selectedNoteID == a)
        #expect(screens.hidesBackButton(.note(a)))
        #expect(!screens.hidesBackButton(.savedVoices), "a screen pushed over it goes back to it")
        screens.show(.settings)
        #expect(screens.selectedNoteID == nil)
        #expect(screens.hidesBackButton(.settings))
    }

    @Test func closingANotePopsItAndTheScreensAboveIt() {
        var screens = ScreenStack(path: [.note(a), .savedVoices])
        screens.close(noteID: b)
        #expect(screens.path == [.note(a), .savedVoices])
        screens.close(noteID: a)
        #expect(screens.path == [])
    }

    // ports: DeepLinksTest#anImportedNoteGoesOnTopWithTheLibraryUnderIt
    /// An imported or recorded note opens on top, or is popped to when it is open already: never a second entry.
    @Test func anOpenedNoteGoesOnTopOrIsPoppedTo() {
        var screens = ScreenStack()
        screens.openNote(a)
        #expect(screens.stack == [.library, .note(a)])
        screens.push(.modelDownload(noteID: a))
        screens.openNote(a)
        #expect(screens.stack == [.library, .note(a)], "no second entry for the same note")
        screens.path = [.note(a, query: "word"), .settings]
        screens.openNote(a)
        #expect(screens.path == [.note(a, query: "word")], "the open screen keeps its query")
    }

    @Test func theModelDownloadOpensOverTheNoteOnlyWhileItIsOnTop() {
        var screens = ScreenStack(path: [.note(a)])
        screens.offerModelDownload(for: a)
        #expect(screens.path == [.note(a), .modelDownload(noteID: a)])
        screens.path = [.note(a), .settings]
        screens.offerModelDownload(for: a)
        #expect(screens.path == [.note(a), .settings])
    }

    // ports: NoteViewModelTest#aRowStartedFromTheLibraryRunsOnceOnly
    @Test func aStartActionRunsOnceForTheScreenAndAgainForAFreshOpen() {
        var screens = ScreenStack()
        screens.show(.note(a, start: .documentInfo))
        #expect(!screens.session(a).started)
        screens.markStarted(a)
        screens.push(.savedVoices)
        screens.openNote(a)
        #expect(screens.session(a).started, "popping back to the screen keeps it")
        screens.popToLibrary()
        #expect(screens.session(a) == NoteSession(), "the session leaves with the screen")
        screens.show(.note(a, start: .documentInfo))
        #expect(!screens.session(a).started, "a fresh open runs it")
    }

    // ports: NoteViewModelTest#searchFromTheLibraryIsPrefilledAndStepsThroughMatches
    /// The kept stack carries no start action and each note's search as the user left it: changed, or closed.
    @Test func theKeptStackCarriesTheSearchesAndNoStartAction() {
        var screens = ScreenStack()
        screens.push(.note(a, query: "word", start: .export(.subtitles)))
        screens.push(.note(b, query: "other"))
        screens.keepSearch("words", for: a)
        screens.keepSearch(nil, for: b)
        var restored = ScreenStack()
        restored.restore(screens.encodedPath)
        #expect(restored.path == [.note(a, query: "words"), .note(b)])
    }

    @Test func aRestoreLeavesAnOpenStackAndAnUnreadableOneAlone() {
        var screens = ScreenStack(path: [.trash])
        screens.restore(ScreenStack(path: [.settings]).encodedPath)
        #expect(screens.path == [.trash])
        var empty = ScreenStack()
        empty.restore(Data("garbage".utf8))
        #expect(empty.path == [])
    }

    @Test func theBackLabelOfANoteComesFromTheScreenBelowWhateverItWasOpenedWith() {
        let screens = ScreenStack(path: [.settings, .note(a, query: "word", start: .rename)])
        #expect(screens.below(noteID: a) == .settings)
        #expect(screens.below(noteID: b) == nil)
        #expect(screens.below(.settings) == .library)
    }

    @Test func settingAStackRootsItAndKeepsTheSharedBottom() {
        var screens = ScreenStack(path: [.settings, .licenses])
        screens.markStarted(a)
        screens.set([.settings, .savedVoices])
        #expect(screens.path == [.settings, .savedVoices])
        #expect(screens.sessions.isEmpty, "no session without its screen")
    }
}

@Suite struct NoteStartActionTests {
    /// The Library's start actions are the Note screen's own effects.
    @Test func eachStartActionIsANoteEffect() {
        #expect(NoteStartAction.export(.subtitles).effect == .exportTranscript(.subtitles))
        #expect(NoteStartAction.documentInfo.effect == .documentInfo)
        #expect(NoteStartAction.rename.effect == .rename)
    }
}
