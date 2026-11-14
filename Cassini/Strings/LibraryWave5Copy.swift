// Generated from cassini-ux 31973ff9784fcc66c1c7993b903a336e8f2c1432; do not edit.
import Foundation
import CassiniNotebook

/// Shared Wave 5 first-run hero and backup-gated privacy copy, resolved using the current app language.
enum LibraryWave5Copy {
    static var heroPhoneBackupQualifier: String {
        String(localized: "firstRun.hero.phoneBackupQualifier", table: "LibraryWave5")
    }
    static var heroSubtitle: String {
        String(localized: "firstRun.hero.subtitle", table: "LibraryWave5")
    }
    static var heroSubtitlePhoneNote: String {
        String(localized: "firstRun.hero.subtitlePhoneNote", table: "LibraryWave5")
    }
    static var heroTitle: String {
        String(localized: "firstRun.hero.title", table: "LibraryWave5")
    }
    static var ipadPrivacyBackupExcluded: String {
        String(localized: "privacy.onDevice.ipad.backupExcluded", table: "LibraryWave5")
    }
    static var ipadPrivacyWithBackup: String {
        String(localized: "privacy.onDevice.ipad.withBackup", table: "LibraryWave5")
    }
    static var iphonePrivacyBackupExcluded: String {
        String(localized: "privacy.onDevice.iphone.backupExcluded", table: "LibraryWave5")
    }
    static var iphonePrivacyWithBackup: String {
        String(localized: "privacy.onDevice.iphone.withBackup", table: "LibraryWave5")
    }

    static func privacyLine(_ privacy: FirstRunPrivacy, device: FirstRunDevice) -> String {
        switch (device, privacy) {
        case (.phone, .withBackup): iphonePrivacyWithBackup
        case (.phone, .backupExcluded): iphonePrivacyBackupExcluded
        case (.pad, .withBackup): ipadPrivacyWithBackup
        case (.pad, .backupExcluded): ipadPrivacyBackupExcluded
        }
    }

    static func template(_ key: String, language: String = DefaultLabels.appLanguage, bundle: Bundle = .main) -> String {
        let locale = Locale(identifier: language)
        let selected = Bundle.preferredLocalizations(from: bundle.localizations,
            forPreferences: [language.replacingOccurrences(of: "_", with: "-")]).first ?? "en"
        let localized = bundle.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle
        switch key {
        case "firstRun.hero.phoneBackupQualifier":
            return String(localized: "firstRun.hero.phoneBackupQualifier", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.subtitle":
            return String(localized: "firstRun.hero.subtitle", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.subtitlePhoneNote":
            return String(localized: "firstRun.hero.subtitlePhoneNote", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.title":
            return String(localized: "firstRun.hero.title", table: "LibraryWave5", bundle: localized, locale: locale)
        case "privacy.onDevice.ipad.backupExcluded":
            return String(localized: "privacy.onDevice.ipad.backupExcluded", table: "LibraryWave5", bundle: localized, locale: locale)
        case "privacy.onDevice.ipad.withBackup":
            return String(localized: "privacy.onDevice.ipad.withBackup", table: "LibraryWave5", bundle: localized, locale: locale)
        case "privacy.onDevice.iphone.backupExcluded":
            return String(localized: "privacy.onDevice.iphone.backupExcluded", table: "LibraryWave5", bundle: localized, locale: locale)
        case "privacy.onDevice.iphone.withBackup":
            return String(localized: "privacy.onDevice.iphone.withBackup", table: "LibraryWave5", bundle: localized, locale: locale)
        default:
            preconditionFailure("Unknown shared Wave 5 library key: \(key)")
        }
    }
}
