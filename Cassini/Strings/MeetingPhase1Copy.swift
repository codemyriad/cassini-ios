// Generated from cassini-ux 5e0c34e0f1bb390298dabdf4eedc494e933fd329; do not edit.
import Foundation

/// Shared meeting copy, resolved using the current app language.
enum MeetingPhase1Copy {
    static var stop: String {
        String(localized: "common.stop", table: "MeetingPhase1")
    }
    static var allMeetings: String {
        String(localized: "library.allMeetings", table: "MeetingPhase1")
    }
    static var backToAllMeetings: String {
        String(localized: "library.backToAllMeetings", table: "MeetingPhase1")
    }
    static var findPlaceholder: String {
        String(localized: "meeting.find.placeholder", table: "MeetingPhase1")
    }
    static var resume: String {
        String(localized: "phone.row.resume", table: "MeetingPhase1")
    }
    static var pause: String {
        String(localized: "player.pause", table: "MeetingPhase1")
    }

    static func template(_ key: String, language: String, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "common.stop":
            return String(localized: "common.stop", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "library.allMeetings":
            return String(localized: "library.allMeetings", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "library.backToAllMeetings":
            return String(localized: "library.backToAllMeetings", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "meeting.find.placeholder":
            return String(localized: "meeting.find.placeholder", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "phone.row.resume":
            return String(localized: "phone.row.resume", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "player.pause":
            return String(localized: "player.pause", table: "MeetingPhase1", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared meeting key: \(key)")
        }
    }
}
