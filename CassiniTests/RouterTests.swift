import XCTest
import CassiniEngine
@testable import Cassini

@MainActor final class RouterTests: XCTestCase {
    func testTheLibraryPushesOnPhonesAndReplacesTheDetailInSplitView() {
        let router = Router()
        let a = UUID(), b = UUID()
        router.show(.note(a))
        router.show(.settings)
        XCTAssertEqual(router.stack, [.library, .note(a), .settings])
        router.isSplit = true
        router.show(.note(b))
        XCTAssertEqual(router.path, [.note(b)])
    }

    func testClosingANotePopsItAndTheScreensAboveIt() {
        let router = Router()
        let a = UUID(), b = UUID()
        router.push(.note(a))
        router.push(.savedVoices)
        router.close(noteID: b)
        XCTAssertEqual(router.path, [.note(a), .savedVoices])
        router.close(noteID: a)
        XCTAssertEqual(router.path, [])
    }

    /// A note's start action runs when the Library opens it; the stack kept with the scene carries none, so a restored
    /// screen does not ask again. Its search is kept.
    func testARestoredStackCarriesNoStartAction() {
        let router = Router()
        let a = UUID()
        router.push(.note(a, query: "word", start: .export(.subtitles)))
        XCTAssertEqual(router.path, [.note(a, query: "word", start: .export(.subtitles))], "the live screen keeps it")
        let restored = Router()
        restored.restore(router.encodedPath)
        XCTAssertEqual(restored.path, [.note(a, query: "word")])
    }

    // ports: NoteViewModelTest#aRowStartedFromTheLibraryRunsOnceOnly
    /// The router remembers that a note's start action ran, so a screen SwiftUI builds again does not run it again;
    /// opening the note from the Library again is a fresh screen.
    func testAStartActionRunsOnceForTheScreenAndAgainForAFreshOpen() {
        let router = Router()
        let a = UUID()
        router.show(.note(a, start: .documentInfo))
        XCTAssertFalse(router.session(a).started)
        router.markStarted(a)
        XCTAssertTrue(router.session(a).started, "a rebuilt screen finds it ran")
        router.push(.savedVoices)
        router.openNote(a)
        XCTAssertTrue(router.session(a).started, "popping back to the screen keeps it")
        router.popToLibrary()
        XCTAssertFalse(router.isOpen(a))
        XCTAssertEqual(router.session(a), NoteSession(), "the screen left the stack, and a leaving screen runs nothing")
        router.show(.note(a, start: .documentInfo))
        XCTAssertFalse(router.session(a).started, "a fresh open runs it")
    }

    // ports: NoteViewModelTest#searchFromTheLibraryIsPrefilledAndStepsThroughMatches
    /// The stack kept with the scene carries the note's search as the user left it: changed, or closed.
    func testARestoredNoteHasItsSearchAsTheUserLeftIt() {
        let router = Router()
        let a = UUID(), b = UUID()
        router.push(.note(a, query: "word"))
        router.push(.note(b, query: "other"))
        router.keepSearch("words", for: a)
        router.keepSearch(nil, for: b)
        let restored = Router()
        restored.restore(router.encodedPath)
        XCTAssertEqual(restored.path, [.note(a, query: "words"), .note(b)], "the closed search stays closed")
    }

    /// A search left open goes with its screen: the same note opened again starts with the Library's query only.
    func testANoteOpenedAgainDoesNotBringBackTheSearchItWasLeftWith() {
        let router = Router()
        let a = UUID()
        router.show(.note(a))
        router.keepSearch("foo", for: a)
        router.popToLibrary()
        router.show(.note(a))
        XCTAssertNil(router.session(a).search)
        let restored = Router()
        restored.restore(router.encodedPath)
        XCTAssertEqual(restored.path, [.note(a)])
    }

    func testTheBackLabelOfANoteComesFromTheScreenBelowWhateverItWasOpenedWith() {
        let router = Router()
        let a = UUID()
        router.push(.note(a, query: "word", start: .rename))
        XCTAssertEqual(router.below(noteID: a), .library)
        XCTAssertNil(router.below(noteID: UUID()))
    }

    func testOpeningANoteThatIsOpenPopsToIt() {
        let router = Router()
        let a = UUID()
        router.push(.note(a, query: "word"))
        router.push(.settings)
        router.openNote(a)
        XCTAssertEqual(router.path, [.note(a, query: "word")])
        router.popToLibrary()
        router.openNote(a)
        XCTAssertEqual(router.path, [.note(a)])
    }

    func testTheBackLabelComesFromTheScreenBelow() {
        let router = Router()
        router.push(.settings); router.push(.trash)
        XCTAssertEqual(router.below(.trash), .settings)
        router.popToLibrary(); router.push(.trash)
        XCTAssertEqual(router.below(.trash), .library)
    }

    func testTheStackSurvivesSceneStorage() {
        let router = Router()
        let a = UUID()
        router.push(.note(a, start: .rename)); router.push(.savedVoices)
        let restored = Router()
        restored.restore(router.encodedPath)
        XCTAssertEqual(restored.path, [.note(a), .savedVoices], "the start action ran once and is not restored")
        restored.restore(Data("garbage".utf8))
        XCTAssertEqual(restored.path, [.note(a), .savedVoices], "an unreadable saved stack changes nothing")
    }

    func testRecordingIsAFullScreenCover() {
        let router = Router()
        router.presentRecording()
        XCTAssertEqual(router.fullScreen, .recording)
        router.dismissRecording()
        XCTAssertNil(router.fullScreen)
    }
}
