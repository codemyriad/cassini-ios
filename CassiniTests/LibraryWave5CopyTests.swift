import CoreGraphics
import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

/// D105 first-run copy, D98 Settings variants and conversation-wave geometry.
@MainActor struct LibraryWave5CopyTests {
    @Test func nativeCompiledWave5CopyResolvesEverySharedKeyInAllSixLanguages() {
        let keys = [
            "firstRun.hero.title",
            "firstRun.hero.subtitle.iphone",
            "firstRun.hero.subtitle.ipad",
            "firstRun.privacy.iphone",
            "firstRun.privacy.ipad",
            "firstRun.privacy.backups.ios",
        ]
        let expected: [(String, [String])] = [
            ("en", [
                "Every word written down.",
                "Right here, on this iPhone.",
                "Right here, on this iPad.",
                "Transcribed on this iPhone.",
                "Transcribed on this iPad.",
                "Backups follow your iCloud settings.",
            ]),
            ("it", [
                "Ogni parola trascritta.",
                "Proprio qui, su questo iPhone.",
                "Proprio qui, su questo iPad.",
                "Trascritto su questo iPhone.",
                "Trascritto su questo iPad.",
                "I backup seguono le impostazioni di iCloud.",
            ]),
            ("fr", [
                "Chaque mot transcrit.",
                "Ici même, sur cet iPhone.",
                "Ici même, sur cet iPad.",
                "Transcrit sur cet iPhone.",
                "Transcrit sur cet iPad.",
                "Les sauvegardes suivent vos réglages iCloud.",
            ]),
            ("es", [
                "Cada palabra transcrita.",
                "Aquí mismo, en este iPhone.",
                "Aquí mismo, en este iPad.",
                "Transcrito en este iPhone.",
                "Transcrito en este iPad.",
                "Las copias de seguridad siguen tus ajustes de iCloud.",
            ]),
            ("pt-BR", [
                "Cada palavra transcrita.",
                "Aqui mesmo, neste iPhone.",
                "Aqui mesmo, neste iPad.",
                "Transcrito neste iPhone.",
                "Transcrito neste iPad.",
                "Os backups seguem os seus ajustes do iCloud.",
            ]),
            ("pt-PT", [
                "Cada palavra transcrita.",
                "Aqui mesmo, neste iPhone.",
                "Aqui mesmo, neste iPad.",
                "Transcrito neste iPhone.",
                "Transcrito neste iPad.",
                "As cópias de segurança seguem as suas definições de iCloud.",
            ]),
        ]
        for (language, values) in expected {
            for (key, expectedText) in zip(keys, values) {
                #expect(LibraryWave5Copy.template(key, language: language) == expectedText)
            }
        }
        #expect(LibraryWave5Copy.template("firstRun.hero.title", language: "fr_CA") == "Chaque mot transcrit.")
    }

    @Test func conversationKeepsItsPausesFadeAndBoundsAtPhoneAndSidebarWidths() {
        for width in [CGFloat(280), 361, 528] {
            let ltr = HeroWaveMetrics.bars(width: width, height: 44)
            let rtl = HeroWaveMetrics.bars(width: width, height: 44, rightToLeft: true)
            #expect(ltr.count == rtl.count)
            #expect(ltr.allSatisfy { $0.rect.width == 3 && $0.rect.height >= 3 && $0.rect.maxX <= width })
            #expect(ltr.first?.rect.minX == 0)
            #expect(ltr.last?.rect.maxX == width)
            #expect(ltr.first?.alpha == 1)
            #expect(ltr.last?.alpha == 0.5)
            for (left, right) in zip(ltr, rtl) {
                #expect(abs(left.rect.minX - (width - right.rect.maxX)) < 0.001)
                #expect(left.rect.height == right.rect.height && left.alpha == right.alpha)
            }
        }
        let drawn = HeroWaveMetrics.bars(width: 351, height: 44)
        #expect(drawn.count == 59)
        // Two eased pauses and one sharp cut, followed by the quieter fourth phrase.
        #expect(drawn[15].rect.height == 7 && drawn[17].rect.height == 7)
        #expect(drawn[34].rect.height == 7 && drawn[35].rect.height == 27)
        #expect(drawn[47].rect.height == 7 && drawn[49].rect.height == 7)
        #expect(drawn[51].rect.height == 12)
        #expect(HeroWaveMetrics.bars(width: 2, height: 44).isEmpty)
        #expect(HeroWaveMetrics.bars(width: 361, height: 0).isEmpty)
    }
}
