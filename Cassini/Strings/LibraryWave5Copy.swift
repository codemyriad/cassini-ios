// Generated from cassini-ux d9bf213a30179c395657e8d8ecd34fe2b987af1a; do not edit.
import Foundation
import CassiniNotebook

/// D105 first-run hero and D98 Settings privacy copy, resolved using the current app language.
enum LibraryWave5Copy {
    static var heroSubtitleIpad: String {
        String(localized: "firstRun.hero.subtitle.ipad", table: "LibraryWave5")
    }
    static var heroSubtitleIphone: String {
        String(localized: "firstRun.hero.subtitle.iphone", table: "LibraryWave5")
    }
    static var heroTitle: String {
        String(localized: "firstRun.hero.title", table: "LibraryWave5")
    }
    static var firstRunPrivacyBackups: String {
        String(localized: "firstRun.privacy.backups.ios", table: "LibraryWave5")
    }
    static var firstRunPrivacyIpad: String {
        String(localized: "firstRun.privacy.ipad", table: "LibraryWave5")
    }
    static var firstRunPrivacyIphone: String {
        String(localized: "firstRun.privacy.iphone", table: "LibraryWave5")
    }

    static func template(_ key: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "firstRun.hero.subtitle.ipad":
            return String(localized: "firstRun.hero.subtitle.ipad", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.subtitle.iphone":
            return String(localized: "firstRun.hero.subtitle.iphone", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.title":
            return String(localized: "firstRun.hero.title", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.privacy.backups.ios":
            return String(localized: "firstRun.privacy.backups.ios", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.privacy.ipad":
            return String(localized: "firstRun.privacy.ipad", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.privacy.iphone":
            return String(localized: "firstRun.privacy.iphone", table: "LibraryWave5", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared Wave 5 library key: \(key)")
        }
    }
}
