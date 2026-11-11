import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct BackStackTests {
    let a = UUID(), b = UUID(), n = UUID()

    // ports: DeepLinksTest#theLibraryIsAlwaysAtTheBottom
    @Test func theLibraryIsAlwaysAtTheBottom() {
        #expect(BackStack.rooted([.trash]) == [.library, .trash])
        #expect(BackStack.rooted([.trash, .library]) == [.library, .trash])
        #expect(BackStack.rooted([]) == [.library])
    }

    // ports: DeepLinksTest#replacingAStackKeepsTheSharedBottom
    @Test func replacingAStackKeepsTheSharedBottom() {
        var stack: [Route] = [.library, .settings, .licenses]
        stack.replace(with: [.library, .settings, .savedVoices])
        #expect(stack == [.library, .settings, .savedVoices])
        stack.replace(with: [.library])
        #expect(stack == [.library])
    }

    // ports: DeepLinksTest#theKeyBelowAScreenPicksItsBackLabel
    @Test func theKeyBelowAScreenPicksItsBackLabel() {
        #expect(BackStack.below(.trash, in: [.library, .settings, .trash]) == .settings)
        #expect(BackStack.below(.trash, in: [.library, .trash]) == .library)
        let consent: [Route] = [.library, .note(n), .modelDownload(noteID: n), .licenses]
        #expect(BackStack.below(.licenses, in: consent) == .modelDownload(noteID: n))
        #expect(BackStack.below(.licenses, in: [.licenses]) == nil)
        #expect(BackStack.below(.trash, in: [.library]) == nil)
    }

    // ports: DeepLinksTest#aNoteNotificationKeepsPopsToOrPushesTheNote
    @Test func aNoteKeepsPopsToOrPushesTheNote() {
        let onTop: [Route] = [.library, .note(a, query: "word")]
        #expect(BackStack.popOrPush(onTop, .note(a)) == onTop)
        let lower: [Route] = [.library, .note(a), .settings]
        #expect(BackStack.popOrPush(lower, .note(a)) == [.library, .note(a)])
        let absent: [Route] = [.library, .settings]
        #expect(BackStack.popOrPush(absent, .note(b)) == [.library, .settings, .note(b)])
        #expect(BackStack.popOrPush([], .note(b)) == [.library, .note(b)])
    }

    @Test func routesSurviveSceneStorage() throws {
        let stack: [Route] = [.library, .note(a, query: "q", start: .export(.subtitles)), .modelDownload(noteID: nil), .trash]
        let data = try JSONEncoder().encode(stack)
        #expect(try JSONDecoder().decode([Route].self, from: data) == stack)
    }
    @Test func standaloneModelRoutesKeepTheirPartAndReadLegacyRoutes() throws {
        let old = Data(#"{"modelDownload":{}}"#.utf8)
        #expect(try JSONDecoder().decode(Route.self, from: old) == .modelDownload(noteID: nil))
        for part in ModelPart.allCases {
            let route = Route.modelDownload(noteID: nil, part: part)
            let data = try JSONEncoder().encode(route)
            #expect(try JSONDecoder().decode(Route.self, from: data) == route)
            #expect(route != .modelDownload(noteID: nil))
        }
    }

}
