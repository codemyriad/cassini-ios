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
    static var transcribingDetailsA11y: String {
        String(localized: "transcribing.details.a11y", table: "MeetingPhase1")
    }
    static var transcribingHeading: String {
        String(localized: "transcribing.heading", table: "MeetingPhase1")
    }
    static var speakerSuggestionNo: String {
        String(localized: "transcribing.speakerSuggestion.no", table: "MeetingPhase1")
    }
    static var speakerSuggestionYes: String {
        String(localized: "transcribing.speakerSuggestion.yes", table: "MeetingPhase1")
    }
    static var statAudioDone: String {
        String(localized: "transcribing.stat.audioDone", table: "MeetingPhase1")
    }
    static var statBatteryAtFinish: String {
        String(localized: "transcribing.stat.batteryAtFinish", table: "MeetingPhase1")
    }
    static var statTimeLeft: String {
        String(localized: "transcribing.stat.timeLeft", table: "MeetingPhase1")
    }
    static var statWordsSoFar: String {
        String(localized: "transcribing.stat.wordsSoFar", table: "MeetingPhase1")
    }
    static var stepPreparing: String {
        String(localized: "transcribing.step.preparing", table: "MeetingPhase1")
    }
    static var stepReading: String {
        String(localized: "transcribing.step.reading", table: "MeetingPhase1")
    }
    static var stepSaving: String {
        String(localized: "transcribing.step.saving", table: "MeetingPhase1")
    }
    static var stepSpeakers: String {
        String(localized: "transcribing.step.speakers", table: "MeetingPhase1")
    }
    static var stepWords: String {
        String(localized: "transcribing.step.words", table: "MeetingPhase1")
    }
    static var stopAndKeepProgress: String {
        String(localized: "transcribing.stopAndKeepProgress", table: "MeetingPhase1")
    }
    static var transcriptSoFar: String {
        String(localized: "transcribing.transcriptSoFar", table: "MeetingPhase1")
    }
    static func speakerSuggestion(name: String) -> String {
        var text = String(localized: "transcribing.speakerSuggestion", table: "MeetingPhase1")
        text = text.replacingOccurrences(of: "{name}", with: name)
        return text
    }
    static func audioDoneValue(done: String, total: String) -> String {
        var text = String(localized: "transcribing.stat.audioDoneValue", table: "MeetingPhase1")
        text = text.replacingOccurrences(of: "{done}", with: done)
        text = text.replacingOccurrences(of: "{total}", with: total)
        return text
    }
    static func etaMinutes(singular: Bool, n: String) -> String {
        let template = singular
            ? String(localized: "transcribing.eta.minutes.one", table: "MeetingPhase1")
            : String(localized: "transcribing.eta.minutes.other", table: "MeetingPhase1")
        return template.replacingOccurrences(of: "{n}", with: n)
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
        case "transcribing.details.a11y":
            return String(localized: "transcribing.details.a11y", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.eta.minutes.one":
            return String(localized: "transcribing.eta.minutes.one", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.eta.minutes.other":
            return String(localized: "transcribing.eta.minutes.other", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.heading":
            return String(localized: "transcribing.heading", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.speakerSuggestion":
            return String(localized: "transcribing.speakerSuggestion", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.speakerSuggestion.no":
            return String(localized: "transcribing.speakerSuggestion.no", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.speakerSuggestion.yes":
            return String(localized: "transcribing.speakerSuggestion.yes", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.stat.audioDone":
            return String(localized: "transcribing.stat.audioDone", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.stat.audioDoneValue":
            return String(localized: "transcribing.stat.audioDoneValue", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.stat.batteryAtFinish":
            return String(localized: "transcribing.stat.batteryAtFinish", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.stat.timeLeft":
            return String(localized: "transcribing.stat.timeLeft", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.stat.wordsSoFar":
            return String(localized: "transcribing.stat.wordsSoFar", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.step.preparing":
            return String(localized: "transcribing.step.preparing", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.step.reading":
            return String(localized: "transcribing.step.reading", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.step.saving":
            return String(localized: "transcribing.step.saving", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.step.speakers":
            return String(localized: "transcribing.step.speakers", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.step.words":
            return String(localized: "transcribing.step.words", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.stopAndKeepProgress":
            return String(localized: "transcribing.stopAndKeepProgress", table: "MeetingPhase1", bundle: localized, locale: locale)
        case "transcribing.transcriptSoFar":
            return String(localized: "transcribing.transcriptSoFar", table: "MeetingPhase1", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared meeting key: \(key)")
        }
    }
}
