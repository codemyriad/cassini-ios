import Foundation
import Testing
@testable import CassiniNotebook

/// D95 applies to Markdown too: sorting/import/seal time cannot become a recording date.
struct MarkdownMeetingTimeTests {
    private let recorded = Date(timeIntervalSince1970: 1_793_088_000)
    private let sealed = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func allThreeMeetingTimeStatesReachTheWriterWithoutACreatedAtFallback() throws {
        let options = try Self.options()
        let texts = ExportTexts(subtitle: { _, _, _ in "Forbidden legacy creation subtitle" }, emptyText: "No words",
            unassignedLabel: "Unknown speaker", markdown: options)
        let cases: [(MeetingTime, String)] = [
            (.instant(recorded), "Tuesday 27 October 2026, 09:00 · 52 min"),
            (.local("2026-11-09T23:15:00"), "2026-11-09T23:15:00 · 52 min"),
            (.unknown, "52 min")
        ]
        let forbidden = options.dateLine(.instant(sealed), 3_120_000)
        for (meetingTime, expected) in cases {
            var note = Note(title: "English recorded planning", createdAt: sealed)
            note.meetingTime = meetingTime
            note.status = .ready
            note.duration = 3_120
            note.transcript = [TranscriptSegment(text: "Hello everyone", start: 0, end: 1, speakerID: "alex")]
            note.speakers = [NoteSpeaker(id: "alex", name: "Alex")]
            let data = try TranscriptExports.data(note, format: .markdown, texts: texts)
            let output = String(decoding: data, as: UTF8.self)
            #expect(output.hasPrefix("# English recorded planning\n\n" + expected + "\n\nSpeakers: Alex\n"))
            #expect(!output.contains(forbidden), "The written date is the meeting time, never the catalogue stamp")
            #expect(!output.contains("Forbidden legacy creation subtitle"))
            #expect(output.contains("Hello everyone"))
        }
    }

    @Test func localLabelDoesNotAcquireTheViewerZoneAndUnknownWithoutDurationOmitsTheDateBlock() throws {
        let label = "2026-11-09T23:15:00"
        for name in ["Pacific/Kiritimati", "America/New_York"] {
            let zone = try #require(TimeZone(identifier: name))
            #expect(MarkdownDate.line(meetingTime: .local(label), timeZone: zone, uiLanguage: "en",
                formattingLocale: Locale(identifier: "en_GB"), duration: "52 min") == label + " · 52 min")
            #expect(MarkdownDate.line(meetingTime: .local(label), timeZone: zone, uiLanguage: "fr",
                formattingLocale: Locale(identifier: "en_US")) == label)
            #expect(MarkdownDate.line(meetingTime: .unknown, timeZone: zone, uiLanguage: "en",
                formattingLocale: Locale(identifier: "en_GB")) == "")
        }
        var note = Note(title: "English undated planning", createdAt: sealed)
        note.meetingTime = .unknown
        note.status = .ready
        note.duration = 0
        note.transcript = [TranscriptSegment(text: "Hello", start: 0, end: 1, speakerID: "alex")]
        note.speakers = [NoteSpeaker(id: "alex", name: "Alex")]
        let texts = ExportTexts(subtitle: { _, _, _ in "Forbidden date" }, emptyText: "No words",
            unassignedLabel: "Unknown speaker", markdown: try Self.options())
        let output = String(decoding: try TranscriptExports.data(note, format: .markdown, texts: texts), as: UTF8.self)
        #expect(output.hasPrefix("# English undated planning\n\nSpeakers: Alex\n\n## Transcript\n"))
        #expect(!output.contains("Forbidden date"))
    }

    private static func options() throws -> MarkdownOptions {
        let locale = Locale(identifier: "en_GB")
        let zone = try #require(TimeZone(identifier: "Europe/Rome"))
        return MarkdownOptions(copy: try MarkdownExportTests.copy("en"), dateLine: { meetingTime, duration in
            MarkdownDate.line(meetingTime: meetingTime, timeZone: zone, uiLanguage: "en", formattingLocale: locale,
                is24Hour: true, duration: MarkdownDate.duration(duration, locale: locale, underMinute: "under 1 min",
                                                               minutes: "{m} min", hours: "{h} h {mm} min"))
        }, untitled: "Untitled meeting", unnamedSpeaker: { "Speaker \($0)" })
    }
}
