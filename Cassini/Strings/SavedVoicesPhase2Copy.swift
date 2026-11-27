// Generated from cassini-ux e709094d283434fa59428544e0065e8deb49967b; do not edit.
import Foundation
import CassiniNotebook

/// Shared Phase 2 Saved voices copy (`L-67`), resolved using the current app language.
enum SavedVoicesPhase2Copy {
    static var forgetBodyTemplate: String {
        String(localized: "confirm.deleteVoiceProfile.body", table: "SavedVoicesPhase2")
    }
    static var forgetPrimary: String {
        String(localized: "confirm.deleteVoiceProfile.primary", table: "SavedVoicesPhase2")
    }
    static var forgetTitleTemplate: String {
        String(localized: "confirm.deleteVoiceProfile.title", table: "SavedVoicesPhase2")
    }
    static var addVoice: String {
        String(localized: "savedVoices.addVoice", table: "SavedVoicesPhase2")
    }
    static var caption: String {
        String(localized: "savedVoices.caption", table: "SavedVoicesPhase2")
    }
    static var empty: String {
        String(localized: "savedVoices.empty", table: "SavedVoicesPhase2")
    }
    static var emptyBody: String {
        String(localized: "savedVoices.empty.body", table: "SavedVoicesPhase2")
    }
    static var footnoteMadeOnIpad: String {
        String(localized: "savedVoices.footnote.madeOn.ipad", table: "SavedVoicesPhase2")
    }
    static var footnoteMadeOnIphone: String {
        String(localized: "savedVoices.footnote.madeOn.iphone", table: "SavedVoicesPhase2")
    }
    static var footnoteNamesOnly: String {
        String(localized: "savedVoices.footnote.namesOnly", table: "SavedVoicesPhase2")
    }
    static var howToAdd: String {
        String(localized: "savedVoices.howToAdd", table: "SavedVoicesPhase2")
    }
    static var rowNeedsNaming: String {
        String(localized: "savedVoices.row.needsNaming", table: "SavedVoicesPhase2")
    }
    static var stale: String {
        String(localized: "savedVoices.row.stale", table: "SavedVoicesPhase2")
    }
    static var staleBodyTemplate: String {
        String(localized: "savedVoices.stale.body", table: "SavedVoicesPhase2")
    }

    static func meetingCount(_ count: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("savedVoices.row.meetingCount", count: count, language: language, bundle: bundle)
    }

    static func staleTitle(_ count: Int, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("savedVoices.stale.title", count: count, language: language, bundle: bundle)
    }

    static func staleBody(_ name: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("savedVoices.stale.body", language: language, bundle: bundle).replacingOccurrences(of: "{name}", with: name)
    }

    static func forgetTitle(_ name: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("confirm.deleteVoiceProfile.title", language: language, bundle: bundle).replacingOccurrences(of: "{name}", with: name)
    }

    static func forgetBody(_ name: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        template("confirm.deleteVoiceProfile.body", language: language, bundle: bundle).replacingOccurrences(of: "{name}", with: name)
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
        case "confirm.deleteVoiceProfile.body":
            return String(localized: "confirm.deleteVoiceProfile.body", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "confirm.deleteVoiceProfile.primary":
            return String(localized: "confirm.deleteVoiceProfile.primary", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "confirm.deleteVoiceProfile.title":
            return String(localized: "confirm.deleteVoiceProfile.title", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.addVoice":
            return String(localized: "savedVoices.addVoice", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.caption":
            return String(localized: "savedVoices.caption", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.empty":
            return String(localized: "savedVoices.empty", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.empty.body":
            return String(localized: "savedVoices.empty.body", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.footnote.madeOn.ipad":
            return String(localized: "savedVoices.footnote.madeOn.ipad", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.footnote.madeOn.iphone":
            return String(localized: "savedVoices.footnote.madeOn.iphone", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.footnote.namesOnly":
            return String(localized: "savedVoices.footnote.namesOnly", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.howToAdd":
            return String(localized: "savedVoices.howToAdd", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.meetingCount":
            return String(localized: "savedVoices.row.meetingCount", defaultValue: "\(count) meetings", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.meta":
            return String(localized: "savedVoices.row.meta", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.needsNaming":
            return String(localized: "savedVoices.row.needsNaming", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.row.stale":
            return String(localized: "savedVoices.row.stale", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.stale.body":
            return String(localized: "savedVoices.stale.body", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        case "savedVoices.stale.title":
            return String(localized: "savedVoices.stale.title", defaultValue: "\(count) voices need naming again", table: "SavedVoicesPhase2", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared Phase 2 saved voices key: \(key)")
        }
    }
}
