import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

/// A placeholder speaker's label is written in the app's language when the speakers are told apart, and every screen
/// shows it as stored (D47): "Voce 2" from an Italian app reads "Voce 2" in any language. A speaker without a label
/// reads "Speaker N" in the app's language. Android still shows its placeholders in the reader's language.
@MainActor @Suite struct SpeakerLabelTests {
    @Test func aLabelShowsAsStored() {
        #expect(NoteCopy.speakerLabel("Voce 2", id: "s2", ordinal: 1) == "Voce 2")
        #expect(NoteCopy.speakerLabel("Speaker 3", id: "s3", ordinal: 0) == "Speaker 3")
        #expect(NoteCopy.speakerLabel("Giulia", id: "s1", ordinal: 0) == "Giulia")
        #expect(NoteCopy.speakerLabel("s4", id: "s4", ordinal: 3) == DefaultLabels.placeholder(4),
                "a label that is the id reads as the speaker's place")
    }

    /// Every language the app ships has a placeholder word to write (`SpeakerNamingFlowTests` checks one written in
    /// Italian).
    @Test func everyLanguageOfTheAppHasAPlaceholderWord() {
        for language in Bundle.main.localizations where language != "Base" {
            #expect(DefaultLabels.words[language] != nil, "\(language)")
        }
    }
}
