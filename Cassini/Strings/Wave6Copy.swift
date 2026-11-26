// Generated from cassini-ux 60ac93da94ce433412c93d8e96a76c68503dcec3; do not edit.
import Foundation
import CassiniNotebook

/// Shared Wave 6 iOS backup and saved-voice copy, resolved using the current app language.
enum Wave6Copy {
    static var backupIncludeSavedVoicesTitle: String {
        String(localized: "backup.includeSavedVoices.title", table: "Wave6")
    }
    static var backupInfoIcloudBody: String {
        String(localized: "backup.info.icloud.body", table: "Wave6")
    }
    static var backupInfoIcloudComputerBody: String {
        String(localized: "backup.info.icloud.computerBody", table: "Wave6")
    }
    static var backupInfoIcloudComputerHeading: String {
        String(localized: "backup.info.icloud.computerHeading", table: "Wave6")
    }
    static var backupInfoIcloudHeading: String {
        String(localized: "backup.info.icloud.heading", table: "Wave6")
    }
    static var backupInfoManualCopyHeading: String {
        String(localized: "backup.info.manualCopy.heading", table: "Wave6")
    }
    static var backupInfoTitle: String {
        String(localized: "backup.info.title", table: "Wave6")
    }
    static var backupInfoWhatBody: String {
        String(localized: "backup.info.what.body", table: "Wave6")
    }
    static var backupPhoneOnlyCardCloseA11y: String {
        String(localized: "backup.phoneOnlyCard.close.a11y", table: "Wave6")
    }
    static var backupSettingsHeading: String {
        String(localized: "backup.settings.heading", table: "Wave6")
    }
    static var backupSettingsLearnMore: String {
        String(localized: "backup.settings.learnMore", table: "Wave6")
    }
    static var commonCancel: String {
        String(localized: "common.cancel", table: "Wave6")
    }
    static var commonNotNow: String {
        String(localized: "common.notNow", table: "Wave6")
    }
    static var commonStop: String {
        String(localized: "common.stop", table: "Wave6")
    }
    static var savedVoicesPrivacyPhone: String {
        String(localized: "savedVoices.privacy.phone", table: "Wave6")
    }
    static var savedVoicesRowForget: String {
        String(localized: "savedVoices.row.forget", table: "Wave6")
    }
    static var savedVoicesRowPlay: String {
        String(localized: "savedVoices.row.play", table: "Wave6")
    }
    static var savedVoicesRowRename: String {
        String(localized: "savedVoices.row.rename", table: "Wave6")
    }
    static var savedVoicesRowSampleCountOne: String {
        String(localized: "savedVoices.row.sampleCount.one", table: "Wave6")
    }
    static var savedVoicesRowSampleCountOther: String {
        String(localized: "savedVoices.row.sampleCount.other", table: "Wave6")
    }
    static var savedVoicesRowStale: String {
        String(localized: "savedVoices.row.stale", table: "Wave6")
    }
    static var savedVoicesRowStatusReady: String {
        String(localized: "savedVoices.row.status.ready", table: "Wave6")
    }
    static var savedVoicesRowStopSample: String {
        String(localized: "savedVoices.row.stopSample", table: "Wave6")
    }
    static var settingsTransferExportHint: String {
        String(localized: "settings.transfer.exportHint", table: "Wave6")
    }
    static var voicesEnrollAddAction: String {
        String(localized: "voices.enroll.addAction", table: "Wave6")
    }
    static var voicesEnrollFromTranscriptHint: String {
        String(localized: "voices.enroll.fromTranscriptHint", table: "Wave6")
    }
    static var voicesEnrollInstructions: String {
        String(localized: "voices.enroll.instructions", table: "Wave6")
    }
    static var voicesEnrollReady: String {
        String(localized: "voices.enroll.ready", table: "Wave6")
    }
    static var voicesEnrollRecord: String {
        String(localized: "voices.enroll.record", table: "Wave6")
    }
    static var voicesEnrollRecording: String {
        String(localized: "voices.enroll.recording", table: "Wave6")
    }
    static var voicesEnrollSave: String {
        String(localized: "voices.enroll.save", table: "Wave6")
    }
    static var voicesEnrollTestPhrase: String {
        String(localized: "voices.enroll.testPhrase", table: "Wave6")
    }
    static var voicesEnrollTestPhraseLabel: String {
        String(localized: "voices.enroll.testPhraseLabel", table: "Wave6")
    }
    static var voicesEnrollTitle: String {
        String(localized: "voices.enroll.title", table: "Wave6")
    }
    static var voicesEnrollTooShort: String {
        String(localized: "voices.enroll.tooShort", table: "Wave6")
    }
    static var voicesSetupBody: String {
        String(localized: "voices.setup.body", table: "Wave6")
    }
    static var voicesSetupEnable: String {
        String(localized: "voices.setup.enable", table: "Wave6")
    }
    static var voicesSetupPrivacyPhone: String {
        String(localized: "voices.setup.privacy.phone", table: "Wave6")
    }
    static var voicesSetupTitle: String {
        String(localized: "voices.setup.title", table: "Wave6")
    }

    static func template(_ key: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "backup.includeSavedVoices.title":
            return String(localized: "backup.includeSavedVoices.title", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.icloud.body":
            return String(localized: "backup.info.icloud.body", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.icloud.computerBody":
            return String(localized: "backup.info.icloud.computerBody", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.icloud.computerHeading":
            return String(localized: "backup.info.icloud.computerHeading", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.icloud.heading":
            return String(localized: "backup.info.icloud.heading", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.manualCopy.heading":
            return String(localized: "backup.info.manualCopy.heading", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.title":
            return String(localized: "backup.info.title", table: "Wave6", bundle: localized, locale: locale)
        case "backup.info.what.body":
            return String(localized: "backup.info.what.body", table: "Wave6", bundle: localized, locale: locale)
        case "backup.phoneOnlyCard.close.a11y":
            return String(localized: "backup.phoneOnlyCard.close.a11y", table: "Wave6", bundle: localized, locale: locale)
        case "backup.settings.heading":
            return String(localized: "backup.settings.heading", table: "Wave6", bundle: localized, locale: locale)
        case "backup.settings.learnMore":
            return String(localized: "backup.settings.learnMore", table: "Wave6", bundle: localized, locale: locale)
        case "common.cancel":
            return String(localized: "common.cancel", table: "Wave6", bundle: localized, locale: locale)
        case "common.notNow":
            return String(localized: "common.notNow", table: "Wave6", bundle: localized, locale: locale)
        case "common.stop":
            return String(localized: "common.stop", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.privacy.phone":
            return String(localized: "savedVoices.privacy.phone", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.forget":
            return String(localized: "savedVoices.row.forget", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.play":
            return String(localized: "savedVoices.row.play", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.rename":
            return String(localized: "savedVoices.row.rename", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.sampleCount.one":
            return String(localized: "savedVoices.row.sampleCount.one", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.sampleCount.other":
            return String(localized: "savedVoices.row.sampleCount.other", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.stale":
            return String(localized: "savedVoices.row.stale", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.status.ready":
            return String(localized: "savedVoices.row.status.ready", table: "Wave6", bundle: localized, locale: locale)
        case "savedVoices.row.stopSample":
            return String(localized: "savedVoices.row.stopSample", table: "Wave6", bundle: localized, locale: locale)
        case "settings.transfer.exportHint":
            return String(localized: "settings.transfer.exportHint", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.addAction":
            return String(localized: "voices.enroll.addAction", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.fromTranscriptHint":
            return String(localized: "voices.enroll.fromTranscriptHint", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.instructions":
            return String(localized: "voices.enroll.instructions", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.ready":
            return String(localized: "voices.enroll.ready", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.record":
            return String(localized: "voices.enroll.record", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.recording":
            return String(localized: "voices.enroll.recording", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.save":
            return String(localized: "voices.enroll.save", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.testPhrase":
            return String(localized: "voices.enroll.testPhrase", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.testPhraseLabel":
            return String(localized: "voices.enroll.testPhraseLabel", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.title":
            return String(localized: "voices.enroll.title", table: "Wave6", bundle: localized, locale: locale)
        case "voices.enroll.tooShort":
            return String(localized: "voices.enroll.tooShort", table: "Wave6", bundle: localized, locale: locale)
        case "voices.setup.body":
            return String(localized: "voices.setup.body", table: "Wave6", bundle: localized, locale: locale)
        case "voices.setup.enable":
            return String(localized: "voices.setup.enable", table: "Wave6", bundle: localized, locale: locale)
        case "voices.setup.privacy.phone":
            return String(localized: "voices.setup.privacy.phone", table: "Wave6", bundle: localized, locale: locale)
        case "voices.setup.title":
            return String(localized: "voices.setup.title", table: "Wave6", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared Wave 6 key: \(key)")
        }
    }
}
