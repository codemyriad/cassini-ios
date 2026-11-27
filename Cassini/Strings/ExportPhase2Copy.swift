// Generated from cassini-ux e709094d283434fa59428544e0065e8deb49967b; do not edit.
import Foundation
import CassiniNotebook

/// Shared Phase 2 export copy, resolved using the current app language.
enum ExportPhase2Copy {
    static var audioOnlyNote: String {
        String(localized: "export.audioOnly.note", table: "ExportPhase2")
    }
    static var cassiniDescription: String {
        String(localized: "export.cassiniFile.description.short", table: "ExportPhase2")
    }
    static var cassiniFile: String {
        String(localized: "export.cassiniFile.label", table: "ExportPhase2")
    }
    static var exportButton: String {
        String(localized: "export.exportButton", table: "ExportPhase2")
    }
    static var formatGroup: String {
        String(localized: "export.formatGroup.a11y", table: "ExportPhase2")
    }
    static var heading: String {
        String(localized: "export.heading", table: "ExportPhase2")
    }
    static var markdownDescription: String {
        String(localized: "export.markdown.description.short", table: "ExportPhase2")
    }
    static var markdown: String {
        String(localized: "export.markdown.label", table: "ExportPhase2")
    }
    static var originalDescription: String {
        String(localized: "export.originalAudio.description", table: "ExportPhase2")
    }
    static var originalAudio: String {
        String(localized: "export.originalAudio.label", table: "ExportPhase2")
    }
    static var otherFormats: String {
        String(localized: "export.otherFormats", table: "ExportPhase2")
    }
    static var plainTextDescription: String {
        String(localized: "export.plainText.description.short", table: "ExportPhase2")
    }
    static var plainText: String {
        String(localized: "export.plainText.label", table: "ExportPhase2")
    }
    static var srtDescription: String {
        String(localized: "export.srt.description.short", table: "ExportPhase2")
    }
    static var subtitles: String {
        String(localized: "export.subtitles.label", table: "ExportPhase2")
    }
    static var typeWithSize: String {
        String(localized: "export.typeWithSize", table: "ExportPhase2")
    }
    static var vttDescription: String {
        String(localized: "export.vtt.description.short", table: "ExportPhase2")
    }

    static func typeWithSize(_ type: String, size: String) -> String {
        typeWithSize.replacingOccurrences(of: "{type}", with: type).replacingOccurrences(of: "{size}", with: size)
    }
}
