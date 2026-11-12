import CassiniCore
import CryptoKit
import Foundation
import Testing
@testable import CassiniNotebook

struct MarkdownExportTests {
    struct Cases: Decodable {
        struct Case: Decodable {
            struct Input: Decodable {
                struct Speaker: Decodable { let id: String; let name: String }
                struct Item: Decodable { let speaker: String; let startMs: Int64; let endMs: Int64; let text: String }
                struct Note: Decodable { let atMs: Int64; let text: String }
                let title: String, tz: String, uiLanguage: String, formattingLocale: String
                let startMs: Int64, durationMs: Int64?
                let speakers: [Speaker], items: [Item], notes: [Note]
            }
            let name: String, input: Input, expected: String
        }
        let cases: [Case]
    }

    @Test func allSharedS5CasesMatchBytesExactly() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: Self.resource("markdown-cases.json"))
        for vector in cases.cases {
            let input = vector.input
            let date = MarkdownDate.line(at: Date(timeIntervalSince1970: Double(input.startMs) / 1000),
                timeZone: try #require(TimeZone(identifier: input.tz)), uiLanguage: input.uiLanguage,
                formattingLocale: Locale(identifier: input.formattingLocale),
                duration: input.durationMs.map { "\($0 / 60_000) min" })
            let t = ExportTranscript(title: input.title, durationMs: input.durationMs ?? 0,
                words: input.items.map { Word($0.speaker, $0.startMs, $0.endMs, $0.text) },
                labels: Dictionary(uniqueKeysWithValues: input.speakers.map { ($0.id, $0.name) }))
            let actual = MarkdownExport.write(t, dateLine: date, copy: try Self.copy(input.uiLanguage),
                notes: input.notes.map { MarkdownNote(atMs: $0.atMs, text: $0.text) })
            let expected = vector.expected.replacingOccurrences(of: "{DATE_LINE}", with: date)
            #expect(Data(actual.utf8) == Data(expected.utf8), "\(vector.name)")
            #expect(!actual.hasPrefix("\u{FEFF}"))
            #expect(actual.hasSuffix("\n") && !actual.hasSuffix("\n\n"))
        }
    }

    @Test(arguments: D84IntegrationVector.names)
    func allViewerRowsHeadersChipsAndContinuationsMatch(_ name: String) throws {
        let vector = try D84IntegrationVector.load(name)
        let t = ExportTranscript(title: name, durationMs: 0, words: vector.words, labels: [:])
        let actual = MarkdownExport.write(t, dateLine: "", copy: try Self.copy("en"))
        let start = try #require(actual.range(of: "## Transcript\n\n"))
        let blocks = vector.rows.map { row in
            let name = row.continuation ? "" : "**\(row.speaker ?? "unassigned")** · "
            let over = row.over.isEmpty ? "" : " (over \(Self.list(row.over)))"
            let clock = String(ExportClock.srt(Int64(row.startMs.rounded())).split(separator: ",")[0])
            return name + clock + over + "\n" + row.text
        }
        #expect(Data(actual[start.upperBound...].utf8) == Data((blocks.joined(separator: "\n\n") + "\n").utf8))
        if name == "acknowledgment" {
            #expect(actual.contains("Speakers: ada, ben\n"), "Chip-only speakers belong in the inventory")
            #expect(actual.components(separatedBy: "Sounds good.").count == 2)
        }
    }

    @Test func escapingAndUnicodeScalarFilenameLimitsMatchAndroid() {
        #expect(MarkdownExport.escape(" #   heading ") == "\\# heading")
        #expect(MarkdownExport.escape("123. item") == "123\\. item")
        #expect(MarkdownExport.escape("- _one_ [two] <three> \\ `four`") == "\\- \\_one\\_ \\[two\\] \\<three\\> \\\\ \\`four\\`")
        #expect(MarkdownExport.escape("one\u{00A0}\u{2003}two\nthree") == "one two three")
        let decomposed = "Cafe\u{0301}"
        #expect(Data(MarkdownExport.escape(decomposed).utf8) == Data(decomposed.utf8))
        #expect(MarkdownExport.filename(" A/B\\C ", untitled: "Untitled meeting") == "A-B-C.md")
        #expect(MarkdownExport.filename("  ", untitled: "Untitled meeting") == "Untitled meeting.md")
        #expect(MarkdownExport.filename("A:?\u{0085}B", untitled: "Untitled meeting") == "A:?-B.md")
        #expect(MarkdownExport.filename(String(repeating: "a", count: 121), untitled: "Untitled meeting") == String(repeating: "a", count: 120) + ".md")
        #expect(MarkdownExport.filename(String(repeating: "😀", count: 121), untitled: "Untitled meeting") == String(repeating: "😀", count: 57) + ".md")
        let accents = String(repeating: "a\u{0301}", count: 61)
        #expect(MarkdownExport.filename(accents, untitled: "Untitled meeting").dropLast(3).unicodeScalars.count == 120)
        let invisible = "\u{200B}Title\u{200B}"
        #expect(Data(MarkdownExport.filename("\u{00A0}" + invisible + "\u{2003}", untitled: "Untitled meeting").utf8)
                == Data((invisible + ".md").utf8), "Trim separators, preserving Android's stored zero-width scalars")
    }

    @Test func combiningScalarsAndWhitespaceMatchAndroidBytes() {
        let cases = [
            ("#\u{0301} heading", "\\#\u{0301} heading"),
            ("1.\u{0301} item", "1\\.\u{0301} item"),
            ("1\u{0301}. item", "1\u{0301}. item"),
            ("one\u{0085}two", "one\u{0085}two"),
            ("\u{000B}one\u{202F}\u{2028}two\u{000C}", "one two")
        ]
        for (input, expected) in cases {
            #expect(Data(MarkdownExport.escape(input).utf8) == Data(expected.utf8))
        }
    }

    @Test func overlapNamesKeepDistinctStoredUnicodeBytes() throws {
        let transcript = ExportTranscript(title: "English overlap", durationMs: 10_000,
            words: [Word("host", 0, 10_000, "Host"), Word("first", 1_000, 5_000, "First"), Word("second", 2_000, 6_000, "Second")],
            labels: ["host": "Host", "first": "René", "second": "Rene\u{0301}"], endsBoundedByAudio: true)
        let output = MarkdownExport.write(transcript, dateLine: "", copy: try Self.copy("en"))
        let header = try #require(output.split(separator: "\n").first { $0.hasPrefix("**Host**") })
        #expect(Data(header.utf8) == Data("**Host** · 00:00:00 (over René and Rene\u{0301})".utf8))
        #expect(Data(output.utf8).range(of: Data("Speakers: Host, René, Rene\u{0301}\n".utf8)) != nil)
    }

    @Test func personalNotesUseOnlyTheD13NamespaceAndValidNumbers() throws {
        let manifest = try JSON.parseObject(#"{"x":{"gocassini.com":{"notes":[{"atMs":1000,"text":"English note"},{"atMs":1.5,"text":"fraction"},{"atMs":"2","text":"string"},{"atMs":-1,"text":"negative"},{"atMs":true,"text":"boolean"},{"atMs":2,"text":4},{"atMs":1e0,"text":"Integral"}]},"codemyriad.io":{"notes":[{"atMs":0,"text":"Wrong namespace"}]}},"meeting":{"notes":[{"atMs":0,"text":"Wrong field"}]}}"#)
        #expect(MarkdownExport.notes(in: manifest) == [.init(atMs: 1000, text: "English note"), .init(atMs: 1, text: "Integral")])
        let output = MarkdownExport.write(ExportTranscript(title: "Notes", durationMs: 0, words: [], labels: [:]),
            dateLine: "", copy: try Self.copy("en"), notes: [.init(atMs: 2000, text: "Last"), .init(atMs: 0, text: "First"), .init(atMs: 0, text: "Second")])
        #expect(output.hasSuffix("## Notes\n\n- 00:00:00 First\n- 00:00:00 Second\n- 00:00:02 Last\n"))
    }

    @Test func dateWordsAndNumericClockAreIndependent() throws {
        let original = Locale.current
        let date = Date(timeIntervalSince1970: 1_793_088_000)
        let line = MarkdownDate.line(at: date, timeZone: try #require(TimeZone(identifier: "Europe/Rome")),
            uiLanguage: "fr", formattingLocale: Locale(identifier: "en_US"), is24Hour: false)
        #expect(line == "mardi 27 octobre 2026, 9:00 AM")
        #expect(Locale.current == original)
        #expect(MarkdownDate.line(at: date, timeZone: TimeZone(secondsFromGMT: 0)!, uiLanguage: "de",
            formattingLocale: Locale(identifier: "en_US"), is24Hour: true) == "Tuesday 27 October 2026, 08:00")
    }

    @Test func meetingDurationFloorsAndUsesNumericLocale() {
        let cases: [(Int64, String?)] = [(0, nil), (-1, nil), (1, "under 1 min"), (59_999, "under 1 min"),
            (60_000, "1 min"), (3_599_999, "59 min"), (3_600_000, "1 h 00 min"), (3_779_999, "1 h 02 min"),
            (3_780_000, "1 h 03 min"), (7_199_999, "1 h 59 min"), (7_200_000, "2 h 00 min")]
        for (ms, expected) in cases {
            #expect(MarkdownDate.duration(ms, locale: Locale(identifier: "en_GB"), underMinute: "under 1 min", minutes: "{m} min", hours: "{h} h {mm} min") == expected)
        }
        #expect(MarkdownDate.duration(3_780_000, locale: Locale(identifier: "ar_EG"), underMinute: "under 1 min", minutes: "{m} min", hours: "{h} h {mm} min") == "١ h ٠٣ min")
    }

    @Test func vendoredFilesMatchPinnedBytes() throws {
        let pin = try JSON.parseObject(String(decoding: Self.resource("UPSTREAM.json"), as: UTF8.self))
        #expect(pin["repository"]?.string == "https://github.com/codemyriad/cassini-ux")
        for (name, info) in try #require(pin["files"]?.object).pairs {
            let digest = SHA256.hash(data: try Self.resource(name)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == info.object?["sha256"]?.string, "\(name)")
        }
    }

    static func resource(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "markdown"))
        return try Data(contentsOf: url)
    }

    static func copy(_ language: String) throws -> MarkdownCopy {
        let entries = try #require(JSON.parseObject(String(decoding: resource("strings.json"), as: UTF8.self))["entries"]?.array)
        func text(_ id: String) throws -> String {
            let entry = try #require(entries.first { $0.object?["id"]?.string == id }?.object)
            return try #require(language == "en" ? entry["en"]?.string : entry["l10n"]?.object?[language]?.object?["text"]?.string)
        }
        return try MarkdownCopy(speakersLine: text("export.markdown.speakersLine"), transcriptHeading: text("export.markdown.transcriptHeading"),
            notesHeading: text("export.markdown.notesHeading"), overLine: text("meeting.turn.over"), speakerList: list)
    }

    static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
