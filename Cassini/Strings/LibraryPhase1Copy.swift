// Generated from cassini-ux 5e0c34e0f1bb390298dabdf4eedc494e933fd329; do not edit.
import Foundation
import CassiniNotebook

/// Shared library copy, resolved using the current app language.
enum LibraryPhase1Copy {
    static var close: String {
        String(localized: "common.close", table: "LibraryPhase1")
    }
    static var record: String {
        String(localized: "common.record", table: "LibraryPhase1")
    }
    static var importAudio: String {
        String(localized: "import.button.mobile", table: "LibraryPhase1")
    }
    static var noSpeech: String {
        String(localized: "phone.row.noSpeech", table: "LibraryPhase1")
    }
    static var transcribedAccessibilityLabel: String {
        String(localized: "phone.row.transcribed.a11y", table: "LibraryPhase1")
    }
    static var searchAccessibilityLabel: String {
        String(localized: "search.field.a11y", table: "LibraryPhase1")
    }
    static var searchPlaceholder: String {
        String(localized: "search.field.placeholder", table: "LibraryPhase1")
    }
    static var searchResultsAccessibilityLabel: String {
        String(localized: "search.results.a11y", table: "LibraryPhase1")
    }
    static var searchTitle: String {
        String(localized: "search.title", table: "LibraryPhase1")
    }

    static func speakerCount(_ count: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("phone.row.speakerCount", count: count, language: language, bundle: bundle)
    }

    static func searchCount(results: Int, meetings: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("format.searchCount.join", language: language, bundle: bundle)
            .replacingOccurrences(of: "{places}", with: template("format.searchCount.places", count: results, language: language, bundle: bundle))
            .replacingOccurrences(of: "{meetings}", with: template("format.searchCount.meetings", count: meetings, language: language, bundle: bundle))
    }

    static func template(_ key: String, count: Int = 0, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "common.close":
            return String(localized: "common.close", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "common.record":
            return String(localized: "common.record", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "format.searchCount.join":
            return String(localized: "format.searchCount.join", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "format.searchCount.meetings":
            return String(localized: "format.searchCount.meetings", defaultValue: "\(count) meetings", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "format.searchCount.places":
            return String(localized: "format.searchCount.places", defaultValue: "\(count) places", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "import.button.mobile":
            return String(localized: "import.button.mobile", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "phone.row.noSpeech":
            return String(localized: "phone.row.noSpeech", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "phone.row.speakerCount":
            return String(localized: "phone.row.speakerCount", defaultValue: "\(count) speakers", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "phone.row.transcribed.a11y":
            return String(localized: "phone.row.transcribed.a11y", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.field.a11y":
            return String(localized: "search.field.a11y", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.field.placeholder":
            return String(localized: "search.field.placeholder", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.results.a11y":
            return String(localized: "search.results.a11y", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.title":
            return String(localized: "search.title", table: "LibraryPhase1", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared library key: \(key)")
        }
    }
}
