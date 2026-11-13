import SwiftUI
import Testing
import CassiniNotebook
@testable import Cassini

@MainActor @Suite struct StatusBadgeViewTests {
    @Test func actualBadgeInkAndFillUseTheContractRolesInBothAppearances() {
        let cases: [(BadgePresentation.Tint, CassiniTokens.Role, CassiniTokens.Role?)] = [
            (.red, .recordInk, .recordTint), (.neutral, .ink2, nil),
            (.amber, .warnInk, .warnTint), (.outline, .ink2, nil)
        ]
        for (tint, ink, fill) in cases {
            let view = StatusBadgeView(badge: .init(kind: .recording, text: "Example", tint: tint, glyph: .dot))
            for scheme in [ColorScheme.light, .dark] {
                #expect(ContrastTests.resolved(view.ink, scheme) == ContrastTests.resolved(CassiniTokens.color(ink), scheme))
                if let fill {
                    #expect(ContrastTests.resolved(view.background, scheme) == ContrastTests.resolved(CassiniTokens.color(fill), scheme))
                    #expect(ContrastTests.contrast(view.ink, on: [CassiniTokens.color(.ground), view.background], scheme) >= 4.5)
                } else if tint == .neutral {
                    #expect(ContrastTests.resolved(view.background, scheme) ==
                            ContrastTests.resolved(Color.ink.opacity(0.1), scheme))
                    #expect(ContrastTests.contrast(view.ink, on: [Color.ground, view.background], scheme) >= 4.5)
                } else {
                    #expect(ContrastTests.resolved(view.background, scheme).opacity == 0)
                    #expect(ContrastTests.contrast(view.ink, on: [CassiniTokens.color(.ground)], scheme) >= 4.5)
                }
            }
        }
    }

    @Test func transcribingSpinnerUsesAccentAndOtherGlyphsKeepTheirInk() {
        for kind in [BadgePresentation.Kind.transcribing, .saving, .importing] {
            let view = StatusBadgeView(badge: .init(kind: kind, text: "Example", tint: .neutral, glyph: .spinner))
            for scheme in [ColorScheme.light, .dark] {
                #expect(ContrastTests.resolved(view.glyphInk, scheme) ==
                        ContrastTests.resolved(kind == .transcribing ? Color.accent : Color.ink2, scheme))
            }
        }
    }

    @Test func actualPillHasDefaultHeightAndGrowsForAccessibleTranslations() {
        let presentation = StatusBadges.transcribing(etaMinutes: nil, text: { StatusBadgeCopy.template($0) })
        let standard = UIHostingController(rootView: StatusBadgeView(badge: presentation).dynamicTypeSize(.large))
        standard.loadViewIfNeeded()
        let size = standard.sizeThatFits(in: CGSize(width: 400, height: 1_000))
        #expect(abs(size.height - 22) < 0.5)
        let long = StatusBadges.transcribing(etaMinutes: 0, text: { StatusBadgeCopy.template($0, language: "fr") })
        let accessible = UIHostingController(rootView: StatusBadgeView(badge: long).dynamicTypeSize(.accessibility5))
        accessible.loadViewIfNeeded()
        let larger = accessible.sizeThatFits(in: CGSize(width: 200, height: 1_000))
        #expect(larger.width <= 200.5 && larger.height > size.height)
    }

    @Test func phoneStatesUseTheSharedLabelsAndKeepPausedPosition() {
        let cases: [(LibraryRow.Status, String)] = [(.queued, "Queued"), (.paused(atMs: 1_792_000), "Paused at 29:52"),
            (.failed, "Couldn’t transcribe"), (.audioOnly, "Audio only"), (.unplayable, "Can’t play"),
            (.unreadable, "Can’t read transcript"), (.newerFormat, "Newer format")]
        for (status, expected) in cases {
            #expect(PhoneStatusBadgeView(status: status).text(language: "en") == expected)
        }
        for language in ["en", "it", "fr", "es", "pt-BR", "pt-PT"] {
            for id in ["queued", "pausedAt", "couldntTranscribe", "audioOnly", "cantPlay", "cantReadTranscript", "newerFormat"] {
                let key = "states.phone." + id
                #expect(StatusBadgeCopy.template(key, language: language) != key)
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
