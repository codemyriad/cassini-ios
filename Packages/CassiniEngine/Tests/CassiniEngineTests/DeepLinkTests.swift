import Foundation
import Testing
import CassiniEngine

@Suite struct DeepLinkTests {
    let id = UUID()

    // ports: DeepLinksTest#parsesTheNotificationExtras
    @Test func parsesTheNotificationExtras() {
        let info = DeepLinks.userInfo(noteID: id)
        #expect(DeepLinks.parse(userInfo: info) == .note(id))
        #expect(DeepLinks.parse(userInfo: info, action: DeepLinks.resumeAction) == .note(id, resume: true))
        #expect(DeepLinks.parse(userInfo: info, action: "com.apple.UNNotificationDefaultActionIdentifier") == .note(id))
        #expect(DeepLinks.parse(url: URL(string: "cassini://recording")!) == .recording)
        #expect(DeepLinks.parse(url: URL(string: "cassini://note/\(id.uuidString)")!) == .note(id))
    }

    // ports: DeepLinksTest#theLauncherAndUnknownExtrasAskForNothing
    @Test func theLauncherAndUnknownExtrasAskForNothing() {
        #expect(DeepLinks.parse(userInfo: [:]) == nil)
        #expect(DeepLinks.parse(userInfo: [DeepLinks.openKey: DeepLinks.openNote]) == nil)
        #expect(DeepLinks.parse(userInfo: [DeepLinks.openKey: DeepLinks.openNote, DeepLinks.noteIDKey: " "]) == nil)
        #expect(DeepLinks.parse(userInfo: [DeepLinks.openKey: "settings", DeepLinks.noteIDKey: id.uuidString]) == nil)
        #expect(DeepLinks.parse(url: URL(string: "cassini://settings")!) == nil)
        #expect(DeepLinks.parse(url: URL(string: "cassini://note/x")!) == nil)
        #expect(DeepLinks.parse(url: URL(string: "https://example.org/recording")!) == nil)
    }

    // ports: DeepLinksTest#aNoteNotificationKeepsPopsToOrPushesTheNote
    @Test func aNoteNotificationKeepsPopsToOrPushesTheNote() {
        let other = UUID()
        let onTop: [Route] = [.library, .note(id, query: "word")]
        #expect(DeepLinks.note(onTop, id) == onTop)
        #expect(DeepLinks.note([.library, .note(id), .settings], id) == [.library, .note(id)])
        #expect(DeepLinks.note([.library, .settings], other) == [.library, .settings, .note(other)])
        #expect(DeepLinks.note([], other) == [.library, .note(other)])
    }
}
