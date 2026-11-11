import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of the transcript exports, in the Export table.
enum ExportCopy {
    /// The localized lines a transcript export carries.
    static func texts(locale: Locale, timeZone: TimeZone) -> ExportTexts {
        ExportTexts(
            subtitle: { createdAt, durationMs, speakers in
                subtitle(createdAt: createdAt, durationMs: durationMs, speakers: speakers, locale: locale, timeZone: timeZone)
            },
            emptyText: String(localized: "No words were found in this recording.", table: "Export",
                              comment: "The body of a TXT export without words"),
            unassignedLabel: String(localized: "Unknown speaker", table: "Export",
                                    comment: "The label of passages no speaker was found for, in an export"),
            meetingSubtitle: { meetingTime, durationMs, speakers in
                subtitle(meetingTime: meetingTime, durationMs: durationMs, speakers: speakers, locale: locale, timeZone: timeZone)
            })
    }

    /// The TXT subtitle line: "Oct 8, 2026, 3:10 PM · 23:50 · 3 speakers"; the speakers part from 2 on.
    static func subtitle(createdAt: Date, durationMs: Int64, speakers: Int, locale: Locale, timeZone: TimeZone) -> String {
        let date = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        let day = String(localized: "\(createdAt.formatted(date)), \(createdAt.formatted(time))", table: "Export",
                         locale: locale, comment: "A date and a time of day: 8 Oct 2026, 15:10")
        return subtitleParts(day: day, durationMs: durationMs, speakers: speakers, locale: locale)
    }

    static func subtitle(meetingTime: MeetingTime, durationMs: Int64, speakers: Int, locale: Locale, timeZone: TimeZone) -> String {
        if let instant = meetingTime.instant {
            return subtitle(createdAt: instant, durationMs: durationMs, speakers: speakers, locale: locale, timeZone: timeZone)
        }
        return subtitleParts(day: meetingTime.localText, durationMs: durationMs, speakers: speakers, locale: locale)
    }

    private static func subtitleParts(day: String?, durationMs: Int64, speakers: Int, locale: Locale) -> String {
        var parts = [day, ExportClock.clock(durationMs, durationMs: durationMs)].compactMap { $0 }
        if speakers >= 2 {
            parts.append(String(localized: "\(speakers) speakers", table: "Export", locale: locale,
                                comment: "The number of speakers in a TXT export"))
        }
        return parts.joined(separator: " · ")
    }

    /// The menu item of `format`.
    static func title(_ format: TranscriptFormat) -> String {
        switch format {
        case .text: String(localized: "Transcript as text", table: "Export")
        case .subtitles: String(localized: "Subtitles · .srt", table: "Export", comment: "SubRip subtitles, for most video players")
        case .webVTT: String(localized: "Subtitles · .vtt", table: "Export", comment: "WebVTT subtitles, for web players")
        case .json: String(localized: "Timed transcript · JSON", table: "Export")
        }
    }

    /// Why a note's transcript cannot be exported now, shown under the disabled menu item; nil when it can.
    static func reason(_ availability: TranscriptExportAvailability) -> String? {
        switch availability {
        case .available: nil
        case .afterTranscription: String(localized: "Available after transcription", table: "Export")
        case .notReadable: String(localized: "Not available for this transcript", table: "Export")
        }
    }

    /// Why an export was not made.
    static func message(_ error: ExportError) -> String {
        if case .notAvailable(let availability) = error, let reason = reason(availability) { return reason }
        return notSaved
    }

    /// An export, or a Cassini document, that could not be written.
    static let notSaved = String(localized: "Couldn’t save the file", table: "Export")
}
