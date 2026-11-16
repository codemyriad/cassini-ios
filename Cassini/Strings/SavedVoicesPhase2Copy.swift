// Generated from cassini-ux 1ffebfa94d02ec966a048d8dded567ce29106702; do not edit.
import Foundation
import CassiniNotebook

/// Shared Phase 2 Saved voices copy (`L-67`), resolved using the current app language.
enum SavedVoicesPhase2Copy {
    static var howToAdd: String {
        String(localized: "savedVoices.howToAdd", table: "SavedVoicesPhase2")
    }
    static var stale: String {
        String(localized: "savedVoices.row.stale", table: "SavedVoicesPhase2")
    }

    static func meetingCount(_ count: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("savedVoices.row.meetingCount", count: count, language: language, bundle: bundle)
    }

    static func meta(meetings: Int, confirmedSpeech: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("savedVoices.row.meta", language: language, bundle: bundle)
            .replacingOccurrences(of: "{meetingCount}", with: meetingCount(meetings, language: language, bundle: bundle))
            .replacingOccurrences(of: "{confirmedSpeech}", with: confirmedSpeech)
    }

    static func template(_ key: String, count: Int = 0, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "savedVoices.howToAdd":
            return String(localized: "savedVoices.howToAdd", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.meetingCount":
            return String(localized: "savedVoices.row.meetingCount", defaultValue: "\(count) meetings", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.meta":
            return String(localized: "savedVoices.row.meta", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.stale":
            return String(localized: "savedVoices.row.stale", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared Phase 2 saved voices key: \(key)")
        }
    }
}
