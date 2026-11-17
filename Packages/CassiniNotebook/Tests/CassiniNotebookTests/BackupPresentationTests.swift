import Foundation
import Testing
@testable import CassiniNotebook

struct BackupPresentationTests {
    @Test(arguments: [false, true], [false, true])
    func inclusionFollowsTheParentAndIndependentVoiceChoice(cloud: Bool, voices: Bool) {
        let state = BackupPresentation(cloud: cloud, voices: voices)
        #expect(state.meetingsIncluded == cloud)
        #expect(state.voicesIncluded == (cloud && voices))
    }

    @Test func noticeWaitsForASavedMeetingAndCommittedBackupState() {
        let state = BackupPresentation(cloud: true, voices: true)
        var note = Note(title: "First meeting")
        func shows(_ notes: [Note], loaded: Bool = true, ready: Bool = true, dismissed: Bool = false) -> Bool {
            state.showsNotice(notes: notes, loaded: loaded, ready: ready, dismissed: dismissed)
        }
        #expect(!shows([]))
        note.audio = .live
        #expect(!shows([note]))
        note.audio = .unplayable(.interrupted)
        #expect(!shows([note]))
        note.audio = .plain
        #expect(shows([note]))
        #expect(!shows([note], loaded: false))
        #expect(!shows([note], ready: false))
        #expect(!shows([note], dismissed: true))
        #expect(!BackupPresentation(cloud: false, voices: true)
            .showsNotice(notes: [note], loaded: true, ready: true, dismissed: false))
        note.trashedAt = Date()
        #expect(!shows([note]))
        note.trashedAt = nil
        note.origin = .imported
        #expect(shows([note]))
        #expect(BackupPresentation(cloud: true, voices: false)
            .showsNotice(notes: [note], loaded: true, ready: true, dismissed: false))
    }
}
