import Foundation
import Testing
@testable import Cassini

/// Independent expected copy from the immutable 5e0c34e shared catalog.
@MainActor struct LibraryPhase1CopyTests {
    @Test func nativeCompiledPlainCopyResolvesEverySharedKeyInAllSixLanguages() {
        let keys = ["search.title", "common.close", "common.record", "import.button.mobile", "phone.row.noSpeech", "search.field.placeholder", "search.field.a11y", "search.results.a11y"]
        let expected: [(String, [String])] = [
            ("en", ["Search", "Close", "Record", "Import audio", "No speech", "Search every meeting", "Search every meeting", "Search results"]),
            ("it", ["Cerca", "Chiudi", "Registra", "Importa audio", "Nessun parlato", "Cerca in tutte le riunioni", "Cerca in tutte le riunioni", "Risultati della ricerca"]),
            ("fr", ["Recherche", "Fermer", "Enregistrer", "Importer un audio", "Aucune parole", "Rechercher dans toutes les réunions", "Rechercher dans toutes les réunions", "Résultats de la recherche"]),
            ("es", ["Buscar", "Cerrar", "Grabar", "Importar audio", "Sin voz", "Buscar en todas las reuniones", "Buscar en todas las reuniones", "Resultados de la búsqueda"]),
            ("pt-BR", ["Buscar", "Fechar", "Gravar", "Importar áudio", "Sem fala", "Buscar em todas as reuniões", "Buscar em todas as reuniões", "Resultados da busca"]),
            ("pt-PT", ["Pesquisar", "Fechar", "Gravar", "Importar áudio", "Sem fala", "Pesquisar em todas as reuniões", "Pesquisar em todas as reuniões", "Resultados da pesquisa"]),
        ]
        for (language, values) in expected {
            for (key, expectedText) in zip(keys, values) {
                #expect(LibraryPhase1Copy.template(key, language: language) == expectedText)
            }
        }
        #expect(LibraryPhase1Copy.template("search.field.placeholder", language: "fr_CA") == "Rechercher dans toutes les réunions")
    }

    // Counts use native locale formatting as well as CLDR plural selection: French uses narrow NBSP,
    // European Portuguese NBSP, English commas, and Italian/Spanish/Brazilian Portuguese periods.
    @Test func nativePluralsKeepZeroOneTwoAndMillionCountsAndIndependentSearchNouns() {
        let cases: [(String, Int, String, String, String)] = [
            ("en", 0, "0 speakers", "0 places in 1 meeting", "1 place in 0 meetings"),
            ("en", 1, "1 speaker", "1 place in 1 meeting", "1 place in 1 meeting"),
            ("en", 2, "2 speakers", "2 places in 1 meeting", "1 place in 2 meetings"),
            ("en", 1000000, "1,000,000 speakers", "1,000,000 places in 1 meeting", "1 place in 1,000,000 meetings"),
            ("it", 0, "0 voci", "0 risultati in 1 riunione", "1 risultato in 0 riunioni"),
            ("it", 1, "1 voce", "1 risultato in 1 riunione", "1 risultato in 1 riunione"),
            ("it", 2, "2 voci", "2 risultati in 1 riunione", "1 risultato in 2 riunioni"),
            ("it", 1000000, "1.000.000 voci", "1.000.000 risultati in 1 riunione", "1 risultato in 1.000.000 riunioni"),
            ("fr", 0, "0 intervenant", "0 occurrence dans 1 réunion", "1 occurrence dans 0 réunion"),
            ("fr", 1, "1 intervenant", "1 occurrence dans 1 réunion", "1 occurrence dans 1 réunion"),
            ("fr", 2, "2 intervenants", "2 occurrences dans 1 réunion", "1 occurrence dans 2 réunions"),
            ("fr", 1000000, "1\u{202F}000\u{202F}000 intervenants", "1\u{202F}000\u{202F}000 occurrences dans 1 réunion", "1 occurrence dans 1\u{202F}000\u{202F}000 réunions"),
            ("es", 0, "0 hablantes", "0 coincidencias en 1 reunión", "1 coincidencia en 0 reuniones"),
            ("es", 1, "1 hablante", "1 coincidencia en 1 reunión", "1 coincidencia en 1 reunión"),
            ("es", 2, "2 hablantes", "2 coincidencias en 1 reunión", "1 coincidencia en 2 reuniones"),
            ("es", 1000000, "1.000.000 hablantes", "1.000.000 coincidencias en 1 reunión", "1 coincidencia en 1.000.000 reuniones"),
            ("pt-BR", 0, "0 locutor", "0 trecho em 1 reunião", "1 trecho em 0 reunião"),
            ("pt-BR", 1, "1 locutor", "1 trecho em 1 reunião", "1 trecho em 1 reunião"),
            ("pt-BR", 2, "2 locutores", "2 trechos em 1 reunião", "1 trecho em 2 reuniões"),
            ("pt-BR", 1000000, "1.000.000 locutores", "1.000.000 trechos em 1 reunião", "1 trecho em 1.000.000 reuniões"),
            ("pt-PT", 0, "0 oradores", "0 ocorrências em 1 reunião", "1 ocorrência em 0 reuniões"),
            ("pt-PT", 1, "1 orador", "1 ocorrência em 1 reunião", "1 ocorrência em 1 reunião"),
            ("pt-PT", 2, "2 oradores", "2 ocorrências em 1 reunião", "1 ocorrência em 2 reuniões"),
            ("pt-PT", 1000000, "1\u{00A0}000\u{00A0}000 oradores", "1\u{00A0}000\u{00A0}000 ocorrências em 1 reunião", "1 ocorrência em 1\u{00A0}000\u{00A0}000 reuniões"),
        ]
        for (language, count, speakers, placesInOneMeeting, onePlaceInMeetings) in cases {
            #expect(LibraryPhase1Copy.speakerCount(count, language: language) == speakers)
            #expect(LibraryPhase1Copy.searchCount(results: count, meetings: 1, language: language) == placesInOneMeeting)
            #expect(LibraryPhase1Copy.searchCount(results: 1, meetings: count, language: language) == onePlaceInMeetings)
        }
    }
}
