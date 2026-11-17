// Generated from cassini-ux 1ffebfa94d02ec966a048d8dded567ce29106702; do not edit.
import Foundation
import CassiniNotebook

/// Shared Phase 2 settings copy, resolved using the current app language.
enum SettingsPhase2Copy {
    static var help: String {
        String(localized: "about.help", table: "SettingsPhase2")
    }
    static var helpSubtitle: String {
        String(localized: "about.help.subtitle", table: "SettingsPhase2")
    }
    static var licenceLine: String {
        String(localized: "about.licenceLine.phone", table: "SettingsPhase2")
    }
    static var licences: String {
        String(localized: "about.licencesNotices", table: "SettingsPhase2")
    }
    static var licencesSubtitle: String {
        String(localized: "about.licencesNotices.subtitle", table: "SettingsPhase2")
    }
    static var nameVersion: String {
        String(localized: "about.nameVersion", table: "SettingsPhase2")
    }
    static var privacy: String {
        String(localized: "about.privacy", table: "SettingsPhase2")
    }
    static var privacyIpad: String {
        String(localized: "about.privacy.subtitle.ipad", table: "SettingsPhase2")
    }
    static var privacyIphone: String {
        String(localized: "about.privacy.subtitle.iphone", table: "SettingsPhase2")
    }
    static var sourceCode: String {
        String(localized: "about.sourceCode", table: "SettingsPhase2")
    }
    static var taglineIpad: String {
        String(localized: "about.tagline.ipad", table: "SettingsPhase2")
    }
    static var taglineIphone: String {
        String(localized: "about.tagline.iphone", table: "SettingsPhase2")
    }
    static var about: String {
        String(localized: "about.title", table: "SettingsPhase2")
    }
    static var version: String {
        String(localized: "about.version", table: "SettingsPhase2")
    }
    static var backupCassiniNever: String {
        String(localized: "backup.info.cassiniNever", table: "SettingsPhase2")
    }
    static var backupRowMeetings: String {
        String(localized: "backup.info.row.meetings", table: "SettingsPhase2")
    }
    static var backupRowMeetingsDetail: String {
        String(localized: "backup.info.row.meetings.detail", table: "SettingsPhase2")
    }
    static var backupRowModels: String {
        String(localized: "backup.info.row.models", table: "SettingsPhase2")
    }
    static var backupRowModelsDetail: String {
        String(localized: "backup.info.row.models.detail.iphone", table: "SettingsPhase2")
    }
    static var backupRowVoicesDetail: String {
        String(localized: "backup.info.row.savedVoices.choice", table: "SettingsPhase2")
    }
    static var backupRowSettings: String {
        String(localized: "backup.info.row.settings", table: "SettingsPhase2")
    }
    static var backupRowSettingsDetail: String {
        String(localized: "backup.info.row.settings.detail", table: "SettingsPhase2")
    }
    static var backupIncluded: String {
        String(localized: "backup.info.status.backedUp", table: "SettingsPhase2")
    }
    static var backupExcluded: String {
        String(localized: "backup.info.status.notBackedUp", table: "SettingsPhase2")
    }
    static var backupWhoComputer: String {
        String(localized: "backup.info.who.computer", table: "SettingsPhase2")
    }
    static var backupWhoComputerDetail: String {
        String(localized: "backup.info.who.computer.detail", table: "SettingsPhase2")
    }
    static var backupWho: String {
        String(localized: "backup.info.who.heading", table: "SettingsPhase2")
    }
    static var backupWhoIcloud: String {
        String(localized: "backup.info.who.icloud.detail", table: "SettingsPhase2")
    }
    static var backupWhoZip: String {
        String(localized: "backup.info.who.zip", table: "SettingsPhase2")
    }
    static var backupWhoZipDetail: String {
        String(localized: "backup.info.who.zip.detail", table: "SettingsPhase2")
    }
    static var backupMeetings: String {
        String(localized: "backup.meetings.switch", table: "SettingsPhase2")
    }
    static var backupMeetingsSubtitle: String {
        String(localized: "backup.meetings.switch.subtitle", table: "SettingsPhase2")
    }
    static var ownCopy: String {
        String(localized: "backup.ownCopy.heading", table: "SettingsPhase2")
    }
    static var zipSubtitle: String {
        String(localized: "backup.ownCopy.zip.subtitle", table: "SettingsPhase2")
    }
    static var backupAnswer: String {
        String(localized: "backup.page.answer.icloud", table: "SettingsPhase2")
    }
    static var backupAnswerBody: String {
        String(localized: "backup.page.answer.icloud.body", table: "SettingsPhase2")
    }
    static var backupVoices: String {
        String(localized: "backup.savedVoices.switch", table: "SettingsPhase2")
    }
    static var backupVoicesWhy: String {
        String(localized: "backup.savedVoices.switch.why", table: "SettingsPhase2")
    }
    static var savedVoices: String {
        String(localized: "common.savedVoices", table: "SettingsPhase2")
    }
    static var speakers: String {
        String(localized: "common.speakers", table: "SettingsPhase2")
    }
    static func meetingCount(_ count: Int) -> String {
        String(localized: "library.meetingCount", defaultValue: "\(count) meetings", table: "SettingsPhase2")
    }
    static var builtIn: String {
        String(localized: "models.builtIn", table: "SettingsPhase2")
    }
    static var download: String {
        String(localized: "models.download", table: "SettingsPhase2")
    }
    static var keepTranscript: String {
        String(localized: "models.keepTranscript", table: "SettingsPhase2")
    }
    static var parakeetDescription: String {
        String(localized: "models.parakeetUltra.description.short", table: "SettingsPhase2")
    }
    static var parakeet: String {
        String(localized: "models.parakeetUltra.name", table: "SettingsPhase2")
    }
    static var recogniseDescription: String {
        String(localized: "models.recogniseVoices.description.short", table: "SettingsPhase2")
    }
    static var recognise: String {
        String(localized: "models.recogniseVoices.name", table: "SettingsPhase2")
    }
    static var on: String {
        String(localized: "models.status.on", table: "SettingsPhase2")
    }
    static var tellApartDescription: String {
        String(localized: "models.tellSpeakersApart.description.short", table: "SettingsPhase2")
    }
    static var tellApart: String {
        String(localized: "models.tellSpeakersApart.name", table: "SettingsPhase2")
    }
    static var whereFrom: String {
        String(localized: "models.whereFrom", table: "SettingsPhase2")
    }
    static var whistleDescription: String {
        String(localized: "models.whistle.description.short", table: "SettingsPhase2")
    }
    static var whistle: String {
        String(localized: "models.whistle.name", table: "SettingsPhase2")
    }
    static func peopleCount(_ count: Int) -> String {
        String(localized: "savedVoices.peopleCount", defaultValue: "\(count) people", table: "SettingsPhase2")
    }
    static var off: String {
        String(localized: "settings.answer.off", table: "SettingsPhase2")
    }
    static var autoName: String {
        String(localized: "settings.ios.speakers.autoName", table: "SettingsPhase2")
    }
    static var autoNameSubtitle: String {
        String(localized: "settings.ios.speakers.autoName.subtitle", table: "SettingsPhase2")
    }
    static var moreDetail: String {
        String(localized: "settings.moreDetail", table: "SettingsPhase2")
    }
    static var aboutSubtitle: String {
        String(localized: "settings.phone.aboutRow.subtitle", table: "SettingsPhase2")
    }
    static func audioHours(_ count: Int) -> String {
        String(localized: "settings.phone.audioHours", defaultValue: "\(count) hours", table: "SettingsPhase2")
    }
    static var backup: String {
        String(localized: "settings.phone.backup", table: "SettingsPhase2")
    }
    static var icloud: String {
        String(localized: "settings.phone.backup.answer.icloud", table: "SettingsPhase2")
    }
    static var app: String {
        String(localized: "settings.phone.group.app", table: "SettingsPhase2")
    }
    static var meetings: String {
        String(localized: "settings.phone.group.meetings", table: "SettingsPhase2")
    }
    static var transcripts: String {
        String(localized: "settings.phone.group.transcripts", table: "SettingsPhase2")
    }
    static var language: String {
        String(localized: "settings.phone.language", table: "SettingsPhase2")
    }
    static var libraryStats: String {
        String(localized: "settings.phone.libraryStats", table: "SettingsPhase2")
    }
    static var runsOnIpad: String {
        String(localized: "settings.phone.speakers.runsOnDevice.ipad", table: "SettingsPhase2")
    }
    static var runsOnIphone: String {
        String(localized: "settings.phone.speakers.runsOnDevice.iphone", table: "SettingsPhase2")
    }
    static var whoIsSpeaking: String {
        String(localized: "settings.phone.speakers.whoIsSpeaking", table: "SettingsPhase2")
    }
    static var afterRecording: String {
        String(localized: "settings.phone.transcription.afterRecording", table: "SettingsPhase2")
    }
    static var forNew: String {
        String(localized: "settings.phone.transcription.forNew", table: "SettingsPhase2")
    }
    static var goingOnline: String {
        String(localized: "settings.phone.transcription.goingOnline", table: "SettingsPhase2")
    }
    static var online: String {
        String(localized: "settings.phone.transcription.online", table: "SettingsPhase2")
    }
    static var rightAway: String {
        String(localized: "settings.phone.transcription.rightAway", table: "SettingsPhase2")
    }
    static var rightAwaySubtitle: String {
        String(localized: "settings.phone.transcription.rightAway.subtitle", table: "SettingsPhase2")
    }
    static var trash: String {
        String(localized: "settings.phone.trash.ios", table: "SettingsPhase2")
    }
    static var transcription: String {
        String(localized: "settings.tab.transcription", table: "SettingsPhase2")
    }
}
