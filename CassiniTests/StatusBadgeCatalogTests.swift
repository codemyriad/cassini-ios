import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

@MainActor struct StatusBadgeCatalogTests {
    @Test func compiledCatalogUsesAllSixInterfaceLanguagesAndKeepsNamedArguments() {
        let expected = [
            ("en", "Transcribing · {n} min", "Importing…"),
            ("it", "In trascrizione · {n} min", "Importazione…"),
            ("fr", "Transcription · {n} min", "Importation…"),
            ("es", "Transcribiendo · {n} min", "Importando…"),
            ("pt-BR", "Transcrevendo · {n} min", "Importando…"),
            ("pt-PT", "A transcrever · {n} min", "A importar…")
        ]
        for (language, transcribing, importing) in expected {
            #expect(StatusBadgeCopy.template("states.badge.transcribing", language: language) == transcribing)
            #expect(StatusBadgeCopy.template("states.badge.importing", language: language) == importing)
            for id in ["states.badge.recording", "states.badge.saving", "states.badge.needsAttention",
                       "states.badge.interrupted", "states.badge.received", "states.badge.transcribing.noEta",
                       "states.badge.transcribing.underMinute", "meeting.interruptedAt"] {
                #expect(StatusBadgeCopy.template(id, language: language) != id)
            }
            let text: StatusBadges.Text = { StatusBadgeCopy.template($0, language: language) }
            #expect(StatusBadges.transcribing(etaMinutes: 4, text: text).text
                == transcribing.replacingOccurrences(of: "{n}", with: "4"))
            #expect(StatusBadges.entry(importing: true, text: text)?.text == importing)
        }
        #expect(StatusBadgeCopy.template("states.badge.importing", language: "fr_CA") == "Importation…")
    }
}
