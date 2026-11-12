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
                    #expect(ContrastTests.contrast(view.ink, on: [view.background, CassiniTokens.color(.ground)], scheme) >= 4.5)
                } else {
                    #expect(ContrastTests.resolved(view.background, scheme).opacity == 0)
                    #expect(ContrastTests.contrast(view.ink, on: [CassiniTokens.color(.ground)], scheme) >= 4.5)
                }
            }
        }
    }

    @Test func appUsesTheGeneratedSixLocaleCatalogInsteadOfShortenedLabels() {
        let english = Locale(identifier: "en")
        let spanish = Locale(identifier: "es")
        let text: StatusBadges.Text = { StatusBadgeCopy.template($0, locale: english) }
        #expect(StatusBadges.transcribing(etaMinutes: 4, text: text).text == "Transcribing · 4 min")
        #expect(StatusBadges.entry(importing: true, text: text)?.text == "Importing…")
        // All catalog languages, including those whose text is long, must resolve a translated template.
        for language in ["en", "it", "fr", "es", "pt-BR", "pt-PT"] {
            let locale = Locale(identifier: language)
            for id in ["states.badge.recording", "states.badge.importing", "states.badge.transcribing", "states.badge.interrupted"] {
                #expect(StatusBadgeCopy.template(id, locale: locale) != id)
            }
        }
        #expect(StatusBadgeCopy.template("states.badge.transcribing", locale: spanish) !=
                StatusBadgeCopy.template("states.badge.transcribing", locale: english))
    }
}
