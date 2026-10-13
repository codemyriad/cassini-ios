import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

/// A note stores a placeholder speaker as "Speaker N" (or "Voce N" from an Italian build); every screen that shows a
/// speaker's label names it in the reader's language, from the Note table, and shows a given name as it is.
@MainActor @Suite struct SpeakerLabelTests {
    @Test func aPlaceholderIsNamedFromTheNoteTable() {
        #expect(NoteCopy.speakerLabel("Voce 2", id: "s2", ordinal: 1) == String(localized: "Speaker \(2)", table: "Note"))
        #expect(NoteCopy.speakerLabel("Speaker 3", id: "s3", ordinal: 0) == String(localized: "Speaker \(3)", table: "Note"))
        #expect(NoteCopy.speakerLabel("s4", id: "s4", ordinal: 3) == String(localized: "Speaker \(4)", table: "Note"),
                "a label that is the id reads as the speaker's place")
        #expect(NoteCopy.speakerLabel("Giulia", id: "s1", ordinal: 0) == "Giulia")
    }

    @Test func theItalianPlaceholderIsVoce() throws {
        let italian = try #require(Bundle.main.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(italian.localizedString(forKey: "Speaker %lld", value: nil, table: "Note") == "Voce %lld")
    }
}
