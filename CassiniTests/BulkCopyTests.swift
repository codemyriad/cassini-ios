import XCTest
import CassiniCore
import CassiniEngine
@testable import Cassini

final class BulkCopyTests: XCTestCase {
    func testPinnedSixLanguageProgressPluralsAndArchiveErrorCopy() throws {
        let cases: [(String, String, String, String, String)] = [
            ("en", "Skipped 1 duplicate", "Skipped 2 duplicates", "Importing 1 of 2…", "This ZIP archive is password-protected. Cassini can’t open password-protected archives."),
            ("it", "1 duplicato saltato", "2 duplicati saltati", "Importazione 1 di 2…", "Questo archivio ZIP è protetto da password. Cassini non può aprire gli archivi protetti da password."),
            ("fr", "1 doublon écarté", "2 doublons écartés", "Importation 1 sur 2…", "Cette archive ZIP est protégée par un mot de passe. Cassini ne peut pas ouvrir les archives protégées par un mot de passe."),
            ("es", "1 duplicado omitido", "2 duplicados omitidos", "Importando 1 de 2…", "Este archivo ZIP está protegido con contraseña. Cassini no puede abrir archivos ZIP protegidos con contraseña."),
            ("pt-BR", "1 duplicata pulada", "2 duplicatas puladas", "Importando 1 de 2…", "Este arquivo ZIP está protegido por senha. O Cassini não pode abrir arquivos ZIP protegidos por senha."),
            ("pt-PT", "1 duplicado omitido", "2 duplicados omitidos", "A importar 1 de 2…", "Este ficheiro ZIP está protegido por palavra-passe. O Cassini não pode abrir ficheiros ZIP protegidos por palavra-passe.")
        ]
        for (language, one, two, progress, error) in cases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(BulkCopy.count("import.summary.duplicates", 1, bundle: bundle), one, language)
            XCTAssertEqual(BulkCopy.count("import.summary.duplicates", 2, bundle: bundle), two, language)
            XCTAssertEqual(BulkCopy.progress("import.progress", BulkProgress(completed: 0, total: 2),
                                             locale: Locale(identifier: "en_US"), bundle: bundle), progress, language)
            XCTAssertEqual(BulkCopy.archiveFailure(.encrypted, bundle: bundle), error, language)
        }
    }

    func testProgressUsesTheCurrentOrdinalAndStaysIndeterminateThroughPacking() {
        XCTAssertEqual(BulkCopy.progress("import.progress", BulkProgress(completed: 0, total: 2)), "Importing 1 of 2…")
        XCTAssertEqual(BulkCopy.progress("import.progress", BulkProgress(completed: 1, total: 2)), "Importing 2 of 2…")
        XCTAssertEqual(BulkCopy.progress("export.zip.progress", BulkProgress(completed: 2, total: 2)), "Exporting 2 of 2…")
    }

    func testSummaryOmitsZeroPartsAndPreservesCanonicalOrder() {
        var summary = BulkImportSummary()
        XCTAssertEqual(BulkCopy.summary(summary), "")
        summary.imported = 2
        summary.unsupported = 1
        XCTAssertEqual(BulkCopy.summary(summary), "Imported 2 · Ignored 1 unsupported file")
        summary.duplicates = 1
        summary.failed = 2
        XCTAssertEqual(BulkCopy.summary(summary),
                       "Imported 2 · Skipped 1 duplicate · Ignored 1 unsupported file · 2 files could not be imported")
    }
}
