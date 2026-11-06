import Foundation
import Testing
@testable import CassiniNotebook

/// A 1 h 03 min call in English with three speakers: a named one, a placeholder and a named one with an
/// accent. Speaker 2's "Yes, yes." comes after Élodie's turn in canonical order but starts while she speaks, so the
/// subtitles sort it into her cues. The expected files are Android's, byte for byte.
struct ExportGoldenTests {
    private let meeting: ExportTranscript

    init() throws {
        let words = try resource("meeting.words.tsv").split(separator: "\n").map { line in
            let field = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return w(field[0], Int64(field[1])!, Int64(field[2])!, field[3])
        }
        meeting = transcript(words, durationMs: 3_790_000, title: "Call with supplier")
    }

    // ports: ExportGoldenTest#text
    @Test func text() throws {
        let subtitle = "8 Oct 2026, 15:10 · 1:03:10 · 3 speakers"
        expectExport(try resource("meeting.txt"), TextExport.write(meeting, subtitle: subtitle, emptyText: "No speech in this recording."))
    }

    // ports: ExportGoldenTest#srt
    @Test func srt() throws {
        expectExport(try resource("meeting.srt"), SrtWriter.write(meeting))
    }

    // ports: ExportGoldenTest#vtt
    @Test func vtt() throws {
        expectExport(try resource("meeting.vtt"), VttWriter.write(meeting))
    }
}
