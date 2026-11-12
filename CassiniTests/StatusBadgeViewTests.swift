import SwiftUI
import Testing
import CassiniNotebook
@testable import Cassini

@MainActor @Suite struct StatusBadgeViewTests {
    @Test func actualBadgeInkAndFillUseTheContractRolesInBothAppearances() {
        let cases: [(BadgePresentation.Tint, CassiniTokens.Role, CassiniTokens.Role?)] = [
            (.red, .recordInk, .recordTint), (.neutral, .ink2, .neutralTint),
            (.amber, .warnInk, .warnTint), (.outline, .ink2, nil)
        ]
        for (tint, ink, fill) in cases {
            let view = StatusBadgeView(badge: .init(kind: .recording, text: "Example", tint: tint, glyph: .dot))
            for scheme in [ColorScheme.light, .dark] {
                #expect(ContrastTests.resolved(view.ink, scheme) == ContrastTests.resolved(CassiniTokens.color(ink), scheme))
                if let fill {
                    #expect(ContrastTests.resolved(view.background, scheme) == ContrastTests.resolved(CassiniTokens.color(fill), scheme))
                    #expect(ContrastTests.contrast(view.ink, on: [CassiniTokens.color(.ground), view.background], scheme) >= 4.5)
                } else {
                    #expect(ContrastTests.resolved(view.background, scheme).opacity == 0)
                    #expect(ContrastTests.contrast(view.ink, on: [CassiniTokens.color(.ground)], scheme) >= 4.5)
                }
            }
        }
    }

    @Test func appUsesTheGeneratedSixLocaleCatalogInsteadOfShortenedLabels() {
        let text: StatusBadges.Text = { StatusBadgeCopy.template($0, language: "en") }
        #expect(StatusBadges.transcribing(etaMinutes: 4, text: text).text == "Transcribing · 4 min")
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
        }
        // A regional identifier must retain the chosen interface language too.
        #expect(StatusBadgeCopy.template("states.badge.importing", language: "fr_CA") == "Importation…")
    }
}
