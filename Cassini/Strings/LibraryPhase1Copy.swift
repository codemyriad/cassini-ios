// Generated from cassini-ux e709094d283434fa59428544e0065e8deb49967b; do not edit.
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
    static var tryAgain: String {
        String(localized: "common.tryAgain", table: "LibraryPhase1")
    }
    static var importAudio: String {
        String(localized: "import.button.mobile", table: "LibraryPhase1")
    }
    static var all: String {
        String(localized: "library.filter.all", table: "LibraryPhase1")
    }
    static var starred: String {
        String(localized: "library.filter.starred", table: "LibraryPhase1")
    }
    static var filtersAccessibilityLabel: String {
        String(localized: "library.filters.a11y", table: "LibraryPhase1")
    }
    static var starredEmpty: String {
        String(localized: "library.starred.empty", table: "LibraryPhase1")
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
    static var anyDate: String {
        String(localized: "search.filter.anyDate", table: "LibraryPhase1")
    }
    static var anySpeaker: String {
        String(localized: "search.filter.anySpeaker", table: "LibraryPhase1")
    }
    static var pastMonth: String {
        String(localized: "search.filter.date.month", table: "LibraryPhase1")
    }
    static var today: String {
        String(localized: "search.filter.date.today", table: "LibraryPhase1")
    }
    static var pastWeek: String {
        String(localized: "search.filter.date.week", table: "LibraryPhase1")
    }
    static var thisYear: String {
        String(localized: "search.filter.date.year", table: "LibraryPhase1")
    }
    static var recordedByMe: String {
        String(localized: "search.filter.recordedByMe", table: "LibraryPhase1")
    }
    static var speakerTemplate: String {
        String(localized: "search.filter.speaker", table: "LibraryPhase1")
    }
    static var speakerNone: String {
        String(localized: "search.filter.speakerNone", table: "LibraryPhase1")
    }
    static var searchStarred: String {
        String(localized: "search.filter.starred", table: "LibraryPhase1")
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
        case "common.tryAgain":
            return String(localized: "common.tryAgain", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "format.searchCount.join":
            return String(localized: "format.searchCount.join", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "format.searchCount.meetings":
            return String(localized: "format.searchCount.meetings", defaultValue: "\(count) meetings", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "format.searchCount.places":
            return String(localized: "format.searchCount.places", defaultValue: "\(count) places", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "import.button.mobile":
            return String(localized: "import.button.mobile", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "library.filter.all":
            return String(localized: "library.filter.all", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "library.filter.starred":
            return String(localized: "library.filter.starred", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "library.filters.a11y":
            return String(localized: "library.filters.a11y", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "library.starred.empty":
            return String(localized: "library.starred.empty", table: "LibraryPhase1", bundle: localized, locale: locale)
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
        case "search.filter.anyDate":
            return String(localized: "search.filter.anyDate", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.anySpeaker":
            return String(localized: "search.filter.anySpeaker", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.date.month":
            return String(localized: "search.filter.date.month", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.date.today":
            return String(localized: "search.filter.date.today", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.date.week":
            return String(localized: "search.filter.date.week", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.date.year":
            return String(localized: "search.filter.date.year", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.recordedByMe":
            return String(localized: "search.filter.recordedByMe", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.speaker":
            return String(localized: "search.filter.speaker", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.speakerNone":
            return String(localized: "search.filter.speakerNone", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.filter.starred":
            return String(localized: "search.filter.starred", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.results.a11y":
            return String(localized: "search.results.a11y", table: "LibraryPhase1", bundle: localized, locale: locale)
        case "search.title":
            return String(localized: "search.title", table: "LibraryPhase1", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared library key: \(key)")
        }
    }
}
