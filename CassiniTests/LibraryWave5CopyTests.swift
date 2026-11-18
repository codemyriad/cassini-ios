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
            "privacy.onDevice.iphone.withBackup",
            "privacy.onDevice.iphone.backupExcluded",
            "privacy.onDevice.ipad.withBackup",
            "privacy.onDevice.ipad.backupExcluded",
        ]
        let expected: [(String, [String])] = [
            ("en", [
                "Every word written down.",
                "Right here, on this iPhone.",
                "Right here, on this iPad.",
                "Transcribed on this iPhone.",
                "Transcribed on this iPad.",
                "Backups follow your iCloud settings.",
                "Transcribed on this iPhone. Never uploaded, except to your encrypted cloud backup.",
                "Transcribed on this iPhone. Cassini never uploads the audio and marks it to be left out of iCloud Backup.",
                "Transcribed on this iPad. Never uploaded, except to your encrypted cloud backup.",
                "Transcribed on this iPad. Cassini never uploads the audio and marks it to be left out of iCloud Backup.",
            ]),
            ("it", [
                "Ogni parola trascritta.",
                "Proprio qui, su questo iPhone.",
                "Proprio qui, su questo iPad.",
                "Trascritto su questo iPhone.",
                "Trascritto su questo iPad.",
                "I backup seguono le impostazioni di iCloud.",
                "Trascritto su questo iPhone. Mai caricato, tranne nel tuo backup crittografato nel cloud.",
                "Trascritto su questo iPhone. Cassini non carica mai l’audio e lo contrassegna per escluderlo dal Backup iCloud.",
                "Trascritto su questo iPad. Mai caricato, tranne nel tuo backup crittografato nel cloud.",
                "Trascritto su questo iPad. Cassini non carica mai l’audio e lo contrassegna per escluderlo dal Backup iCloud.",
            ]),
            ("fr", [
                "Chaque mot transcrit.",
                "Ici même, sur cet iPhone.",
                "Ici même, sur cet iPad.",
                "Transcrit sur cet iPhone.",
                "Transcrit sur cet iPad.",
                "Les sauvegardes suivent vos réglages iCloud.",
                "Transcrit sur cet iPhone. Jamais mis en ligne, sauf dans votre sauvegarde cloud chiffrée.",
                "Transcrit sur cet iPhone. Cassini ne met jamais l’audio en ligne et le marque pour l’exclure de la Sauvegarde iCloud.",
                "Transcrit sur cet iPad. Jamais mis en ligne, sauf dans votre sauvegarde cloud chiffrée.",
                "Transcrit sur cet iPad. Cassini ne met jamais l’audio en ligne et le marque pour l’exclure de la Sauvegarde iCloud.",
            ]),
            ("es", [
                "Cada palabra transcrita.",
                "Aquí mismo, en este iPhone.",
                "Aquí mismo, en este iPad.",
                "Transcrito en este iPhone.",
                "Transcrito en este iPad.",
                "Las copias de seguridad siguen tus ajustes de iCloud.",
                "Transcrito en este iPhone. Nunca se sube, salvo a tu copia de seguridad cifrada en la nube.",
                "Transcrito en este iPhone. Cassini nunca sube el audio y lo marca para dejarlo fuera de Copia en iCloud.",
                "Transcrito en este iPad. Nunca se sube, salvo a tu copia de seguridad cifrada en la nube.",
                "Transcrito en este iPad. Cassini nunca sube el audio y lo marca para dejarlo fuera de Copia en iCloud.",
            ]),
            ("pt-BR", [
                "Cada palavra transcrita.",
                "Aqui mesmo, neste iPhone.",
                "Aqui mesmo, neste iPad.",
                "Transcrito neste iPhone.",
                "Transcrito neste iPad.",
                "Os backups seguem os seus ajustes do iCloud.",
                "Transcrito neste iPhone. Nunca é enviado, exceto para o seu backup criptografado na nuvem.",
                "Transcrito neste iPhone. O Cassini nunca envia o áudio e o marca para ficar fora do Backup do iCloud.",
                "Transcrito neste iPad. Nunca é enviado, exceto para o seu backup criptografado na nuvem.",
                "Transcrito neste iPad. O Cassini nunca envia o áudio e o marca para ficar fora do Backup do iCloud.",
            ]),
            ("pt-PT", [
                "Cada palavra transcrita.",
                "Aqui mesmo, neste iPhone.",
                "Aqui mesmo, neste iPad.",
                "Transcrito neste iPhone.",
                "Transcrito neste iPad.",
                "As cópias de segurança seguem as suas definições de iCloud.",
                "Transcrito neste iPhone. Nunca é enviado, exceto para a sua cópia de segurança encriptada na nuvem.",
                "Transcrito neste iPhone. O Cassini nunca envia o áudio e marca-o para ficar fora da Cópia em iCloud.",
                "Transcrito neste iPad. Nunca é enviado, exceto para a sua cópia de segurança encriptada na nuvem.",
                "Transcrito neste iPad. O Cassini nunca envia o áudio e marca-o para ficar fora da Cópia em iCloud.",
            ]),
        ]
        for (language, values) in expected {
            for (key, expectedText) in zip(keys, values) {
                #expect(LibraryWave5Copy.template(key, language: language) == expectedText)
            }
        }
        #expect(LibraryWave5Copy.template("firstRun.hero.title", language: "fr_CA") == "Chaque mot transcrit.")
    }

    /// PARITY Wave 6 contract §2 / D98: iOS never claims "The audio never leaves it." in any state.
    @Test func devicePrivacyLineSelectsBackupOrExclusionCopyAndNeverClaimsNeverLeaves() {
        let combinations: [(FirstRunDevice, FirstRunPrivacy, String)] = [
            (.phone, .withBackup, "Transcribed on this iPhone. Never uploaded, except to your encrypted cloud backup."),
            (.phone, .backupExcluded, "Transcribed on this iPhone. Cassini never uploads the audio and marks it to be left out of iCloud Backup."),
            (.pad, .withBackup, "Transcribed on this iPad. Never uploaded, except to your encrypted cloud backup."),
            (.pad, .backupExcluded, "Transcribed on this iPad. Cassini never uploads the audio and marks it to be left out of iCloud Backup."),
        ]
        for (device, privacy, expected) in combinations {
            let text = LibraryWave5Copy.privacyLine(privacy, device: device)
            #expect(text == expected)
            #expect(!text.localizedCaseInsensitiveContains("never leaves"))
        }
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
