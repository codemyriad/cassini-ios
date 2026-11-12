import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// The export writers over a transcript at the length limit of one note: 11 h of continuous speech, about 104,000
/// words. Each writer finishes in linear time and gives clocks past 10 h.
struct LongExportTests {
    private static let hourMs: Int64 = 3_600_000
    private static let speakers = 4
    private static let turnWords = 23
    private static let prefix = "diar_0f8e2c3a_6b7d_4e1f_9a2b_3c4d5e6f7a8b_"
    private static let text = ("So, let us start with the main point of today’s meeting. The quarterly numbers look better than "
        + "expected, but we still need to check Thursday’s deliveries and the project budget. "
        + "Can everyone confirm their availability for next week? Perfect, thank you very much everyone.").split(separator: " ").map(String.init)

    /// Android's `LongRun.words`: about 9,500 words an hour, a new speaker each 23 words.
    private static func words(_ endMs: Int64, wordsPerHour: Int64 = 9_500) -> [Word] {
        let gap = hourMs / wordsPerHour
        return (0..<Int(endMs / gap)).map { i -> Word in
            let start = Int64(i) * gap
            return Word("\(prefix)\(1 + (i / turnWords) % speakers)", start, start + gap * 4 / 5, text[i % text.count])
        }.filter { $0.endMs <= endMs }
    }

    // ports: LongExportTest#textSrtAndVttWriteEveryWordOfAnElevenHourTranscript
    @Test func textSrtAndVttWriteEveryWordOfAnElevenHourTranscript() throws {
        let hours: Int64 = 11
        let words = Self.words(hours * Self.hourMs)
        let labels = Dictionary(uniqueKeysWithValues: (1...Self.speakers).map { ("\(Self.prefix)\($0)", "Speaker \($0)") })
        let long = ExportTranscript(title: "Conference day", durationMs: hours * Self.hourMs, words: words, labels: labels)
        let markdownCopy = try MarkdownExportTests.copy("en")

        let ((text, markdown, srt, vtt), elapsed) = try measureThreadCPU {
            (TextExport.write(long, subtitle: "11 Oct 2026", emptyText: "No words"),
             MarkdownExport.write(long, dateLine: "11 Oct 2026", copy: markdownCopy),
             SrtWriter.write(long), VttWriter.write(long))
        }
        if ProcessInfo.processInfo.environment["CASSINI_PERF_GATE"] == "1" {
            #expect(elapsed < .seconds(30), "export writers used \(elapsed) of calling-thread CPU time")
        }
        for export in [text, markdown, srt, vtt] { expectExportShape(export) }
        let last = try #require(words.last).text
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(last))
        #expect(srt.contains("10:59:"), "SRT clock past 10 h")
        #expect(vtt.contains("10:59:"), "VTT clock past 10 h")
        #expect(text.contains("10:"))
        #expect(markdown.contains("10:59:"), "Markdown clock past 10 h")
        let body = try #require(markdown.range(of: "## Transcript\n\n"))
        let exportedWords = markdown[body.upperBound...].components(separatedBy: "\n\n").flatMap {
            $0.split(separator: "\n").dropFirst().joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        }
        #expect(exportedWords == words.map(\.text), "Every word of the eleven-hour recording stays in order")
    }
}
