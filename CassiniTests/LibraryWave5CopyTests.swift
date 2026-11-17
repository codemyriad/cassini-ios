import CoreGraphics
import Foundation
import Testing
import CassiniNotebook
@testable import Cassini

/// Wave 5 first-run hero and backup-gated privacy copy from pinned cassini-ux `b26190b57d8e35391ba9b4bafd177d66b10f0ec3`,
/// plus decorative wave geometry (`W5.2`, `W5.3`, `D-974`, `D98`).
@MainActor struct LibraryWave5CopyTests {
    @Test func nativeCompiledWave5CopyResolvesEverySharedKeyInAllSixLanguages() {
        let keys = [
            "firstRun.hero.title",
            "firstRun.hero.subtitle",
            "firstRun.hero.phoneBackupQualifier",
            "firstRun.hero.subtitlePhoneNote",
            "privacy.onDevice.iphone.withBackup",
            "privacy.onDevice.iphone.backupExcluded",
            "privacy.onDevice.ipad.withBackup",
            "privacy.onDevice.ipad.backupExcluded",
        ]
        let expected: [(String, [String])] = [
            ("en", [
                "Every word written down.",
                "None of it uploaded.",
                "(except for encrypted cloud backup)",
                "None of it uploaded. (except for encrypted cloud backup)",
                "Written down on this iPhone. Never uploaded, except to your encrypted cloud backup.",
                "Written down on this iPhone. Cassini never uploads the audio and marks it to be left out of iCloud Backup.",
                "Written down on this iPad. Never uploaded, except to your encrypted cloud backup.",
                "Written down on this iPad. Cassini never uploads the audio and marks it to be left out of iCloud Backup.",
            ]),
            ("it", [
                "Ogni parola trascritta.",
                "Nulla viene caricato.",
                "(tranne per il backup crittografato nel cloud)",
                "Nulla viene caricato. (tranne per il backup crittografato nel cloud)",
                "Trascritto su questo iPhone. Mai caricato, tranne nel tuo backup crittografato nel cloud.",
                "Trascritto su questo iPhone. Cassini non carica mai l’audio e lo contrassegna per escluderlo dal Backup iCloud.",
                "Trascritto su questo iPad. Mai caricato, tranne nel tuo backup crittografato nel cloud.",
                "Trascritto su questo iPad. Cassini non carica mai l’audio e lo contrassegna per escluderlo dal Backup iCloud.",
            ]),
            ("fr", [
                "Chaque mot transcrit.",
                "Rien n’est mis en ligne.",
                "(sauf pour la sauvegarde cloud chiffrée)",
                "Rien n’est mis en ligne. (sauf pour la sauvegarde cloud chiffrée)",
                "Transcrit sur cet iPhone. Jamais mis en ligne, sauf dans votre sauvegarde cloud chiffrée.",
                "Transcrit sur cet iPhone. Cassini ne met jamais l’audio en ligne et le marque pour l’exclure de la Sauvegarde iCloud.",
                "Transcrit sur cet iPad. Jamais mis en ligne, sauf dans votre sauvegarde cloud chiffrée.",
                "Transcrit sur cet iPad. Cassini ne met jamais l’audio en ligne et le marque pour l’exclure de la Sauvegarde iCloud.",
            ]),
            ("es", [
                "Cada palabra transcrita.",
                "No se sube nada.",
                "(salvo para la copia de seguridad cifrada en la nube)",
                "No se sube nada. (salvo para la copia de seguridad cifrada en la nube)",
                "Transcrito en este iPhone. Nunca se sube, salvo a tu copia de seguridad cifrada en la nube.",
                "Transcrito en este iPhone. Cassini nunca sube el audio y lo marca para dejarlo fuera de Copia en iCloud.",
                "Transcrito en este iPad. Nunca se sube, salvo a tu copia de seguridad cifrada en la nube.",
                "Transcrito en este iPad. Cassini nunca sube el audio y lo marca para dejarlo fuera de Copia en iCloud.",
            ]),
            ("pt-BR", [
                "Cada palavra transcrita.",
                "Nada é enviado.",
                "(exceto para o backup criptografado na nuvem)",
                "Nada é enviado. (exceto para o backup criptografado na nuvem)",
                "Transcrito neste iPhone. Nunca é enviado, exceto para o seu backup criptografado na nuvem.",
                "Transcrito neste iPhone. O Cassini nunca envia o áudio e o marca para ficar fora do Backup do iCloud.",
                "Transcrito neste iPad. Nunca é enviado, exceto para o seu backup criptografado na nuvem.",
                "Transcrito neste iPad. O Cassini nunca envia o áudio e o marca para ficar fora do Backup do iCloud.",
            ]),
            ("pt-PT", [
                "Cada palavra transcrita.",
                "Nada é enviado.",
                "(exceto para a cópia de segurança encriptada na nuvem)",
                "Nada é enviado. (exceto para a cópia de segurança encriptada na nuvem)",
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
            (.phone, .withBackup, "Written down on this iPhone. Never uploaded, except to your encrypted cloud backup."),
            (.phone, .backupExcluded, "Written down on this iPhone. Cassini never uploads the audio and marks it to be left out of iCloud Backup."),
            (.pad, .withBackup, "Written down on this iPad. Never uploaded, except to your encrypted cloud backup."),
            (.pad, .backupExcluded, "Written down on this iPad. Cassini never uploads the audio and marks it to be left out of iCloud Backup."),
        ]
        for (device, privacy, expected) in combinations {
            let text = LibraryWave5Copy.privacyLine(privacy, device: device)
            #expect(text == expected)
            #expect(!text.localizedCaseInsensitiveContains("never leaves"))
        }
    }

    @Test func heroWaveDrawsFourPointBarsFadingTowardTrailingEdgeAndMirrorsInRTL() {
        let ltr = HeroWaveMetrics.bars(width: 156, height: 40, rightToLeft: false)
        #expect(ltr.count == 20)
        #expect(ltr.allSatisfy { $0.rect.width == 4 && $0.rect.height >= 4 })
        #expect(ltr.first?.rect.minX == 0)
        #expect(ltr.first?.alpha == 1)
        #expect(ltr.last?.alpha == 0)

        let rtl = HeroWaveMetrics.bars(width: 156, height: 40, rightToLeft: true)
        #expect(rtl.count == ltr.count)
        #expect(rtl.first?.rect.maxX == 156)
        #expect(rtl.first?.alpha == 1)
        #expect(rtl.last?.alpha == 0)
        #expect(HeroWaveMetrics.bars(width: 2, height: 40).isEmpty)
    }
}
