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

    // ports: NoteViewModelTest#aRowStartedFromTheLibraryRunsOnceOnly
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
        XCTAssertEqual(restored.path, router.path)
        restored.restore(Data("garbage".utf8))
        XCTAssertEqual(restored.path, router.path, "an unreadable saved stack changes nothing")
    }

    func testRecordingIsAFullScreenCover() {
        let router = Router()
        router.presentRecording()
        XCTAssertEqual(router.fullScreen, .recording)
        router.dismissRecording()
        XCTAssertNil(router.fullScreen)
    }
}
