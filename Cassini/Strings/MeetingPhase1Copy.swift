// Generated from cassini-ux 5e0c34e0f1bb390298dabdf4eedc494e933fd329; do not edit.
import Foundation

/// Shared Phase 1 meeting and speaker copy, resolved using the current app language.
enum MeetingPhase1Copy {
    static var cancel: String {
        String(localized: "common.cancel", table: "MeetingPhase1")
    }
    static var quoteTemplate: String {
        String(localized: "common.quote", table: "MeetingPhase1")
    }
    static func quote(_ quote: String) -> String {
        quoteTemplate.replacingOccurrences(of: "{quote}", with: quote)
    }
    static var savedVoices: String {
        String(localized: "common.savedVoices", table: "MeetingPhase1")
    }
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
    static var speakerDialogLabel: String {
        String(localized: "speakers.dialog.a11y", table: "MeetingPhase1")
    }
    static var speakerDuplicateNoticeTemplate: String {
        String(localized: "speakers.duplicate.notice", table: "MeetingPhase1")
    }
    static func speakerDuplicateNotice(_ name: String) -> String {
        speakerDuplicateNoticeTemplate.replacingOccurrences(of: "{name}", with: name)
    }
    static var speakerSamePerson: String {
        String(localized: "speakers.duplicate.samePerson", table: "MeetingPhase1")
    }
    static var speakerSomeoneElse: String {
        String(localized: "speakers.duplicate.someoneElse", table: "MeetingPhase1")
    }
    static var speakerMergeInto: String {
        String(localized: "speakers.mergeInto", table: "MeetingPhase1")
    }
    static var speakerNameLabel: String {
        String(localized: "speakers.nameLabel", table: "MeetingPhase1")
    }
    static var speakerPlaySample: String {
        String(localized: "speakers.playSample", table: "MeetingPhase1")
    }
    static var speakerRememberBodyTemplate: String {
        String(localized: "speakers.rememberVoice.cardBody.iphone", table: "MeetingPhase1")
    }
    static func speakerRememberBody(_ name: String) -> String {
        speakerRememberBodyTemplate.replacingOccurrences(of: "{name}", with: name)
    }
    static var speakerRememberUnnamed: String {
        String(localized: "speakers.rememberVoice.cardBody.iphone.unnamed", table: "MeetingPhase1")
    }
    static var speakerRememberModelsNeeded: String {
        String(localized: "speakers.rememberVoice.modelsNeeded", table: "MeetingPhase1")
    }
    static var speakerRememberTitle: String {
        String(localized: "speakers.rememberVoice.title", table: "MeetingPhase1")
    }
    static var speakerRememberTooShort: String {
        String(localized: "speakers.rememberVoice.tooShort", table: "MeetingPhase1")
    }
    static var speakerSaveName: String {
        String(localized: "speakers.saveName", table: "MeetingPhase1")
    }
    static var speakerVoicesRanked: String {
        String(localized: "speakers.savedVoices.heading", table: "MeetingPhase1")
    }
    static var speakerLikely: String {
        String(localized: "speakers.savedVoices.likely", table: "MeetingPhase1")
    }
    static var speakerTalkTimeTemplate: String {
        String(localized: "speakers.talkTime", table: "MeetingPhase1")
    }
    static func speakerTalkTime(_ talkTime: String) -> String {
        speakerTalkTimeTemplate.replacingOccurrences(of: "{talkTime}", with: talkTime)
    }

    static func template(_ key: String, language: String, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "common.cancel":
            return String(localized: "common.cancel", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "common.quote":
            return String(localized: "common.quote", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "common.savedVoices":
            return String(localized: "common.savedVoices", table: "MeetingPhase1", bundle: localized, locale: locale)
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
        case "speakers.dialog.a11y":
            return String(localized: "speakers.dialog.a11y", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.duplicate.notice":
            return String(localized: "speakers.duplicate.notice", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.duplicate.samePerson":
            return String(localized: "speakers.duplicate.samePerson", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.duplicate.someoneElse":
            return String(localized: "speakers.duplicate.someoneElse", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.mergeInto":
            return String(localized: "speakers.mergeInto", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.nameLabel":
            return String(localized: "speakers.nameLabel", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.playSample":
            return String(localized: "speakers.playSample", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.rememberVoice.cardBody.iphone":
            return String(localized: "speakers.rememberVoice.cardBody.iphone", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.rememberVoice.cardBody.iphone.unnamed":
            return String(localized: "speakers.rememberVoice.cardBody.iphone.unnamed", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.rememberVoice.modelsNeeded":
            return String(localized: "speakers.rememberVoice.modelsNeeded", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.rememberVoice.title":
            return String(localized: "speakers.rememberVoice.title", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.rememberVoice.tooShort":
            return String(localized: "speakers.rememberVoice.tooShort", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.saveName":
            return String(localized: "speakers.saveName", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.savedVoices.heading":
            return String(localized: "speakers.savedVoices.heading", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.savedVoices.likely":
            return String(localized: "speakers.savedVoices.likely", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "speakers.talkTime":
            return String(localized: "speakers.talkTime", table: "MeetingPhase1", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared meeting key: \(key)")
        }
    }
}
