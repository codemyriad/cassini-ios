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

    /// A count reads in its language's CLDR category: 0 is `one` in French and Brazilian Portuguese but `other` in
    /// European Portuguese, Spanish and Italian ("0 note" against "0 notas"). A million is `many` in every language but
    /// English; `many` has the `other` text, so those cases check that the form is there rather than which one is read.
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
        let url = try #require(bundle.url(forResource: "Settings", withExtension: "stringsdict"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let entry = try #require(table["%lld notes"] as? [String: Any])
        let variable = try #require(entry.values.compactMap { $0 as? [String: Any] }.first)
        let form = try #require(variable[category] as? String, "\(language) has no \(category)")
        let locale = Locale(identifier: language)
        let format = bundle.localizedString(forKey: "%lld notes", value: nil, table: "Settings")
        #expect(String(format: format, locale: locale, count) == String(format: form, locale: locale, count))
    }

    /// Settings › App language names the language in its own words, with the region where there are two Portugueses.
    @Test func theAppLanguageRowNamesTheLanguageInItsOwnWords() {
        #expect(Self.languages.map(AppLanguageSection.name(of:))
                == ["English", "Español", "Français", "Italiano", "Português (Brasil)", "Português (Portugal)"])
    }
}
