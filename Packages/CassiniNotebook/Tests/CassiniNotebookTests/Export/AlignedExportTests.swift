import CassiniCore
import CryptoKit
import Foundation
import Testing
@testable import CassiniNotebook

struct AlignedExportTests {
    private func resource(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "export")))
    }
    @Test func sharedMarkdownVectorsAndHarmonyGoldenMatchBytes() throws {
        let cases = try JSONDecoder().decode(MarkdownExportTests.Cases.self, from: resource("markdown-cases.json"))
        for (index, vector) in cases.cases.enumerated() {
            let input = vector.input
            let date = MarkdownDate.line(at: Date(timeIntervalSince1970: Double(input.startMs) / 1000),
                timeZone: try #require(TimeZone(identifier: input.tz)), uiLanguage: input.uiLanguage,
                formattingLocale: Locale(identifier: input.formattingLocale), duration: input.durationMs.map { "\($0 / 60_000) min" })
            let transcript = ExportTranscript(title: input.title, durationMs: input.durationMs ?? 0,
                words: input.items.map { Word($0.speaker, $0.startMs, $0.endMs, $0.text) },
                labels: Dictionary(uniqueKeysWithValues: input.speakers.map { ($0.id, $0.name) }))
            let actual = Data(MarkdownExport.write(transcript, dateLine: date, copy: try MarkdownExportTests.copy(input.uiLanguage),
                notes: input.notes.map { MarkdownNote(atMs: $0.atMs, text: $0.text) }).utf8)
            #expect(actual == Data(vector.expected.replacingOccurrences(of: "{DATE_LINE}", with: date).utf8), "\(vector.name)")
            if index == 0 { #expect(actual == (try resource("budget-review.md"))) }
        }
    }
    @Test func upstreamExportFilesKeepTheirPinnedBytes() throws {
        struct Pin: Decodable { let commit: String; let sha256: [String: String] }
        let pin = try JSONDecoder().decode(Pin.self, from: resource("UPSTREAM.json"))
        #expect(pin.commit.count == 40)
        for (path, digest) in pin.sha256 {
            let bytes = try resource(URL(fileURLWithPath: path).lastPathComponent)
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest)
        }
    }
    // PARITY §2 regression cases; shared TXT/SRT/VTT vectors are absent at the upstream pin.
    @Test func literalSrtAndEscapedWebVtt() {
        let transcript = ExportTranscript(title: "Title", durationMs: 10_000,
            words: [Word("a", 1000, 2500, "<one> & two"), Word("b", 2000, 3000, "Next")],
            labels: ["a": "Ana & <A>", "b": "Ben"])
        #expect(AlignedTextExport.plainText(transcript) == "Ana & <A> · 00:00:01\n<one> & two\n\nBen · 00:00:02\nNext\n")
        #expect(AlignedTextExport.subtitles(transcript, webVTT: false) == "1\n00:00:01,000 --> 00:00:02,500\nAna & <A>: <one> & two\n\n2\n00:00:02,500 --> 00:00:03,000\nBen: Next\n")
        #expect(AlignedTextExport.subtitles(transcript, webVTT: true) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\n<v Ana &amp; &lt;A&gt;>&lt;one&gt; &amp; two</v>\n\n00:00:02.500 --> 00:00:03.000\n<v Ben>Next</v>\n")
    }
    @Test func longTurnsSplitWithoutDroppingWordsOrOverlappingCues() {
        let words = (0..<100).map { Word("a", Int64($0 * 250), Int64($0 * 250 + 200), "word\($0)") }
        let transcript = ExportTranscript(title: "Long", durationMs: 30_000, words: words, labels: ["a": "Ana"])
        let cues = AlignedTextExport.cues(transcript)
        #expect(cues.count > 1)
        #expect(cues.flatMap { $0.text.split(separator: " ").map(String.init) } == words.map(\.text))
        for (index, cue) in cues.enumerated() {
            #expect(cue.endMs > cue.startMs && cue.endMs - cue.startMs <= 7_000)
            if index > 0 { #expect(cue.startMs >= cues[index - 1].endMs) }
            #expect(SubtitleCues.lines(cue.prefix + cue.text, from: cue.prefix.utf16.count).allSatisfy { $0.utf16.count <= 42 })
        }
    }
}
