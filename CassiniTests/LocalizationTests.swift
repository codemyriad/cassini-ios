import Foundation
import Testing
@testable import Cassini

/// The app's languages (D50, D50.1): English, Italian, French, Spanish and both Portuguese variants. Cassini follows the
/// system's language: a regional variant reads as its language, a bare `pt` as Brazilian Portuguese, pt-PT and the
/// other Portuguese regions as European Portuguese, and any other language as English. `scripts/check-strings.sh`
/// checks that every key has every language with the English arguments; these check the built app. An iOS-only check:
/// Android's resources are checked by lint.
@Suite struct LocalizationTests {
    static let languages = ["en", "es", "fr", "it", "pt-BR", "pt-PT"]

    static func bundle(_ language: String) throws -> Bundle {
        try #require(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)), "\(language).lproj")
    }

    @Test func theAppHasSixLanguagesWithEnglishAsItsSource() {
        #expect(Set(Bundle.main.localizations).subtracting(["Base"]) == Set(Self.languages))
        #expect(Bundle.main.developmentLocalization == "en")
    }

    @Test(arguments: [
        (["pt"], "pt-BR"), (["pt-BR"], "pt-BR"), (["pt-PT"], "pt-PT"), (["pt-AO"], "pt-PT"), (["pt-MZ"], "pt-PT"),
        (["fr-CA"], "fr"), (["fr-BE"], "fr"), (["es-MX"], "es"), (["es-419"], "es"), (["it-CH"], "it"), (["en-GB"], "en"),
        (["de"], "en"), (["ja"], "en"), (["de", "pt-PT"], "pt-PT"),
    ])
    func theSystemLanguagePicksOneOfTheApps(preferences: [String], expected: String) {
        #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first == expected)
    }

    /// Every language has every table, translated: the Settings screen's title is never the English key outside English.
    @Test(arguments: languages.filter { $0 != "en" })
    func eachLanguageHasItsOwnWords(language: String) throws {
        let bundle = try Self.bundle(language)
        #expect(bundle.localizedString(forKey: "Settings", value: nil, table: "Settings") != "Settings")
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let prompt = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
            #expect(prompt != key && prompt.contains("Cassini"), "\(language) \(key): \(prompt)")
        }
    }

    /// The label a Cassini document export writes for passages without a speaker (the Export table's) is the one the
    /// Note screen shows them under, in every language (D47: written as the app shows it, and shown as stored).
    @Test(arguments: languages)
    func theExportedUnknownSpeakerIsTheOneTheNoteShows(language: String) throws {
        let bundle = try Self.bundle(language)
        let exported = bundle.localizedString(forKey: "Unknown speaker", value: nil, table: "Export")
        #expect(exported == bundle.localizedString(forKey: "Unknown speaker", value: nil, table: "Note"))
        #expect(language == "en" || exported != "Unknown speaker", "\(language) is translated")
    }

    /// A count reads in its language's CLDR category: 0 is `one` in French and Brazilian Portuguese but `other` in
    /// European Portuguese, Spanish and Italian ("0 réunions" vs "0 réunion", "0 reuniões" vs "0 reunião"). A million
    /// is `many` in every language but English; `many` has the `other` text, so those cases check that the form is
    /// there rather than which one is read.
    @Test(arguments: [
        ("en", 0, "other"), ("en", 1, "one"), ("en", 1_000_000, "other"),
        ("it", 0, "other"), ("it", 1, "one"), ("it", 2, "other"), ("it", 1_000_000, "many"),
        ("fr", 0, "one"), ("fr", 1, "one"), ("fr", 2, "other"), ("fr", 1_000_000, "many"),
        ("es", 0, "other"), ("es", 1, "one"), ("es", 2, "other"), ("es", 1_000_000, "many"),
        ("pt-BR", 0, "one"), ("pt-BR", 1, "one"), ("pt-BR", 2, "other"), ("pt-BR", 1_000_000, "many"),
        ("pt-PT", 0, "other"), ("pt-PT", 1, "one"), ("pt-PT", 2, "other"), ("pt-PT", 1_000_000, "many"),
    ])
    func aCountReadsInItsLanguagesPluralForm(language: String, count: Int, category: String) throws {
        let bundle = try Self.bundle(language)
        let url = try #require(bundle.url(forResource: "SettingsPhase2", withExtension: "stringsdict"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        for key in ["library.meetingCount", "savedVoices.peopleCount", "settings.phone.audioHours"] {
            let entry = try #require(table[key] as? [String: Any])
            let variable = try #require(entry.values.compactMap { $0 as? [String: Any] }.first)
            let form = try #require(variable[category] as? String, "\(language) \(key) has no \(category)")
            let locale = Locale(identifier: language)
            let format = bundle.localizedString(forKey: key, value: nil, table: "SettingsPhase2")
            #expect(String(format: format, locale: locale, count) == String(format: form, locale: locale, count))
        }
    }

    /// Settings › App language names the language in its own words, with the region where there are two Portugueses.
    @Test func theAppLanguageRowNamesTheLanguageInItsOwnWords() {
        #expect(Self.languages.map(AppLanguageSection.name(of:))
                == ["English", "Español", "Français", "Italiano", "Português (Brasil)", "Português (Portugal)"])
    }

    /// L-67 (`D-1047`): Phase 2 screens and shared tables never call a meeting a "note" in any of the six languages.
    /// `Export`'s `"Notes"` key is `export.markdown.notesHeading` (bookmarks/annotations), not a meeting.
    @Test(arguments: languages)
    func phase2TablesNeverCallAMeetingANoteInAnyLanguage(language: String) throws {
        let bundle = try Self.bundle(language)
        let forbidden = try NSRegularExpression(pattern: #"\b(note|notes|nota|notas)\b"#, options: [.caseInsensitive])
        let tables = ["Settings", "SettingsPhase2", "Transcription", "Speakers", "SavedVoicesPhase2", "Trash", "BulkTransfer", "Failures", "Export"]
        for table in tables {
            var checked = 0
            if let url = bundle.url(forResource: table, withExtension: "strings"),
               let entries = NSDictionary(contentsOf: url) as? [String: String] {
                for (key, value) in entries {
                    if table == "Export" && key == "Notes" { continue }
                    checked += 1
                    let range = NSRange(value.startIndex..<value.endIndex, in: value)
                    #expect(forbidden.firstMatch(in: value, range: range) == nil,
                            "\(language) \(table) [\(key)]: \(value)")
                }
            }
            if let url = bundle.url(forResource: table, withExtension: "stringsdict"),
               let entries = NSDictionary(contentsOf: url) as? [String: Any] {
                for (key, rawEntry) in entries {
                    guard let dict = rawEntry as? [String: Any] else { continue }
                    for rawVar in dict.values {
                        guard let variable = rawVar as? [String: Any] else { continue }
                        for category in ["zero", "one", "two", "few", "many", "other"] {
                            guard let value = variable[category] as? String else { continue }
                            checked += 1
                            let range = NSRange(value.startIndex..<value.endIndex, in: value)
                            #expect(forbidden.firstMatch(in: value, range: range) == nil,
                                    "\(language) \(table) [\(key) \(category)]: \(value)")
                        }
                    }
                }
            }
            #expect(checked > 0, "\(language) \(table) had no localized entries")
        }
    }

    @Test func savedVoicesPhase2CopyResolvesCatalogEntriesAndFeminineMeetingCountsInAllSixLanguages() {
        let staleExpected: [(String, String)] = [
            ("en", "Name them again in a meeting to keep recognising them."),
            ("it", "Dai di nuovo il nome in una riunione per continuare a riconoscerla."),
            ("fr", "Nommez à nouveau cette personne dans une réunion pour que Cassini continue à la reconnaître."),
            ("es", "Vuelve a poner nombre a esta persona en una reunión para que Cassini la siga reconociendo."),
            ("pt-BR", "Nomeie essa pessoa de novo em uma reunião para que ela continue sendo reconhecida."),
            ("pt-PT", "Dê novamente nome a esta pessoa numa reunião para que continue a ser reconhecida."),
        ]
        for (language, expected) in staleExpected {
            #expect(SavedVoicesPhase2Copy.template("savedVoices.row.stale", language: language) == expected)
            let howToAdd = SavedVoicesPhase2Copy.template("savedVoices.howToAdd", language: language)
            #expect(!howToAdd.isEmpty)
        }
        #expect(SavedVoicesPhase2Copy.template("savedVoices.row.stale", language: "fr_CA")
                == "Nommez à nouveau cette personne dans une réunion pour que Cassini continue à la reconnaître.")

        let countCases: [(String, Int, String)] = [
            ("en", 0, "0 meetings · 22 min"),
            ("en", 1, "1 meeting · 22 min"),
            ("en", 14, "14 meetings · 22 min"),
            ("en", 1_000_000, "1,000,000 meetings · 22 min"),
            ("it", 0, "0 riunioni · 22 min"),
            ("it", 1, "1 riunione · 22 min"),
            ("it", 14, "14 riunioni · 22 min"),
            ("it", 1_000_000, "1.000.000 riunioni · 22 min"),
            ("fr", 0, "0 réunion · 22 min"),
            ("fr", 1, "1 réunion · 22 min"),
            ("fr", 14, "14 réunions · 22 min"),
            ("fr", 1_000_000, "1\u{202F}000\u{202F}000 réunions · 22 min"),
            ("es", 0, "0 reuniones · 22 min"),
            ("es", 1, "1 reunión · 22 min"),
            ("es", 14, "14 reuniones · 22 min"),
            ("es", 1_000_000, "1.000.000 reuniones · 22 min"),
            ("pt-BR", 0, "0 reunião · 22 min"),
            ("pt-BR", 1, "1 reunião · 22 min"),
            ("pt-BR", 14, "14 reuniões · 22 min"),
            ("pt-BR", 1_000_000, "1.000.000 reuniões · 22 min"),
            ("pt-PT", 0, "0 reuniões · 22 min"),
            ("pt-PT", 1, "1 reunião · 22 min"),
            ("pt-PT", 14, "14 reuniões · 22 min"),
            ("pt-PT", 1_000_000, "1\u{00A0}000\u{00A0}000 reuniões · 22 min"),
        ]
        for (language, count, expected) in countCases {
            #expect(SavedVoicesPhase2Copy.meta(meetings: count, confirmedSpeech: "22 min", language: language) == expected)
        }
    }

    @Test(arguments: languages)
    func aboutLicenceLineNamesCodemyriadOUInEveryLanguage(language: String) throws {
        let bundle = try Self.bundle(language)
        let line = bundle.localizedString(forKey: "about.licenceLine.phone", value: nil, table: "SettingsPhase2")
        #expect(line.contains("Codemyriad OÜ"), "\(language): \(line)")
        #expect(line.contains("{year}"), "\(language): \(line)")
    }
}
