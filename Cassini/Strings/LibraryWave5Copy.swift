// Generated from cassini-ux 160fb923944422c5c4ff01aa777bb572e2a6e96e; do not edit.
import Foundation
import CassiniNotebook

/// D105 first-run hero and D98 Settings privacy copy, resolved using the current app language.
enum LibraryWave5Copy {
    static var heroSubtitleIpad: String {
        String(localized: "firstRun.hero.subtitle.ipad", table: "LibraryWave5")
    }
    static var heroSubtitleIphone: String {
        String(localized: "firstRun.hero.subtitle.iphone", table: "LibraryWave5")
    }
    static var heroTitle: String {
        String(localized: "firstRun.hero.title", table: "LibraryWave5")
    }
    static var firstRunPrivacyBackups: String {
        String(localized: "firstRun.privacy.backups.ios", table: "LibraryWave5")
    }
    static var firstRunPrivacyIpad: String {
        String(localized: "firstRun.privacy.ipad", table: "LibraryWave5")
    }
    static var firstRunPrivacyIphone: String {
        String(localized: "firstRun.privacy.iphone", table: "LibraryWave5")
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
        case "firstRun.hero.subtitle.ipad":
            return String(localized: "firstRun.hero.subtitle.ipad", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.subtitle.iphone":
            return String(localized: "firstRun.hero.subtitle.iphone", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.hero.title":
            return String(localized: "firstRun.hero.title", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.privacy.backups.ios":
            return String(localized: "firstRun.privacy.backups.ios", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.privacy.ipad":
            return String(localized: "firstRun.privacy.ipad", table: "LibraryWave5", bundle: localized, locale: locale)
        case "firstRun.privacy.iphone":
            return String(localized: "firstRun.privacy.iphone", table: "LibraryWave5", bundle: localized, locale: locale)
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
