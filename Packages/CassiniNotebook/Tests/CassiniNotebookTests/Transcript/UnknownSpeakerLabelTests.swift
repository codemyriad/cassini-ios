import Testing
@testable import CassiniNotebook

@Suite struct UnknownSpeakerLabelTests {
    @Test(arguments: [
        ("en", "Unknown speaker"), ("it", "Voce sconosciuta"), ("fr", "Intervenant inconnu"),
        ("es", "Hablante desconocido"), ("pt-BR", "Locutor desconhecido"), ("pt-PT", "Orador desconhecido")
    ])
    func unknownUsesTheRequestedLanguageWhileStoredNamesStayUnchanged(_ language: String, _ expected: String) {
        #expect(SpeakerName.unknown.label(language: language) == expected)
        #expect(DefaultLabels.unknown(language: language) == expected)
        #expect(SpeakerName.named("Ben Carter").label(language: language) == "Ben Carter")
        #expect(SpeakerName.placeholder(2, label: "Voce 2").label(language: language) == "Voce 2")
    }
}
