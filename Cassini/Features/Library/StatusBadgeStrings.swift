// Generated from cassini-ux 793209cb3425bece7143178458fddd94b691e12d; do not edit.
import Foundation

/// Literal call sites keep Xcode extraction and the compiled catalog in agreement.
enum StatusBadgeStrings {
    static func template(_ id: String, bundle: Bundle, locale: Locale) -> String {
        switch id {
        case "meeting.interruptedAt":
            return String(localized: "meeting.interruptedAt", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.importing":
            return String(localized: "states.badge.importing", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.interrupted":
            return String(localized: "states.badge.interrupted", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.needsAttention":
            return String(localized: "states.badge.needsAttention", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.received":
            return String(localized: "states.badge.received", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.recording":
            return String(localized: "states.badge.recording", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.saving":
            return String(localized: "states.badge.saving", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.transcribing":
            return String(localized: "states.badge.transcribing", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.transcribing.noEta":
            return String(localized: "states.badge.transcribing.noEta", table: "StatusBadge", bundle: bundle, locale: locale)
        case "states.badge.transcribing.underMinute":
            return String(localized: "states.badge.transcribing.underMinute", table: "StatusBadge", bundle: bundle, locale: locale)
        default:
            preconditionFailure("Unknown shared status badge key: \(id)")
        }
    }
}
