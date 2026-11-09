import Foundation
import Testing
@testable import CassiniNotebook

struct TextExportTests {
    private let subtitle = "8 Oct 2026, 15:10 · 23:50 · 3 speakers"

    // ports: TextExportTest#manySpeakersWithEnglishText
    @Test func manySpeakersWithEnglishText() {
        let words = said("spk_0", 0, "So, does the delivery slip to Thursday?")
            + said("spk_1", 3_000, "Yes, because the truck has already left.")
            + said("spk_2", 161_500, "Agreed, but the price stays as in the March order.")
            + said("spk_0", 170_000, "Perfect.")
        expectExport("""
            Call with supplier
            8 Oct 2026, 15:10 · 23:50 · 3 speakers

            [00:00] Paolo
            So, does the delivery slip to Thursday?

            [00:03] Speaker 2
            Yes, because the truck has already left.

            [02:41] Élodie
            Agreed, but the price stays as in the March order.

            [02:50] Paolo
            Perfect.

            """, TextExport.write(transcript(words, title: "Call with supplier"), subtitle: subtitle, emptyText: "No speech in this recording."))
    }

    // ports: TextExportTest#oneSpeakerLeavesTheLabelOut
    @Test func oneSpeakerLeavesTheLabelOut() {
        let words = said("spk_1", 1_000, "Testing one two three.")
        expectExport("Test\n8 Oct 2026, 15:10 · 00:04\n\n[00:01]\nTesting one two three.\n",
                     TextExport.write(transcript(words, title: "Test"), subtitle: "8 Oct 2026, 15:10 · 00:04", emptyText: "No speech."))
    }

    // ports: TextExportTest#emptyTranscriptWritesTheEmptyText
    @Test func emptyTranscriptWritesTheEmptyText() {
        expectExport("Test\n8 Oct 2026, 15:10 · 00:04\n\nNo speech in this recording.\n",
                     TextExport.write(transcript([], title: "Test"), subtitle: "8 Oct 2026, 15:10 · 00:04",
                                      emptyText: "No speech in this recording."))
    }

    // ports: TextExportTest#clockFromOneHourAndAMissingLabelUsesTheId
    @Test func clockFromOneHourAndAMissingLabelUsesTheId() {
        let words = said("spk_0", 5_000, "Starting.") + said("spk_9", 3_725_000, "Last thing.")
        expectExport("Meeting\nsub\n\n[0:00:05] Paolo\nStarting.\n\n[1:02:05] spk_9\nLast thing.\n",
                     TextExport.write(transcript(words, durationMs: 3_800_000, title: "Meeting"), subtitle: "sub", emptyText: "-"))
    }

    // ports: TextExportTest#overlappingSpeakersHaveWholeRowsAndCompetingLabels
    @Test func overlappingSpeakersHaveWholeRowsAndCompetingLabels() {
        // The second turn starts before the first one ends; the text follows the canonical word order.
        let words = said("spk_0", 10_000, "I would say yes") + said("spk_1", 10_500, "No wait")
        expectExport("T\ns\n\n[00:10] Paolo (over Speaker 2)\nI would say yes\n\n[00:10] Speaker 2 (over Paolo)\nNo wait\n",
                     TextExport.write(transcript(words, title: "T"), subtitle: "s", emptyText: "-"))
    }
}


extension TextExportTests {
    @Test(arguments: D84IntegrationVector.names)
    func textExportUsesViewerRowsAndInlineChips(_ name: String) throws {
        let vector = try D84IntegrationVector.load(name)
        let output = TextExport.write(transcript(vector.words, labels: [:], title: name), subtitle: "sub", emptyText: "-")
        let blocks = output.components(separatedBy: "\n\n").dropFirst()
        #expect(blocks.count == vector.rows.count)
        for (block, expected) in zip(blocks, vector.rows) {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines) == expected.text)
            let header = String(lines[0])
            if !expected.over.isEmpty {
                #expect(header.contains("(over " + expected.over.joined(separator: " and ") + ")"))
            } else {
                #expect(!header.contains("(over "))
            }
            if expected.continuation, let speaker = expected.speaker {
                #expect(!header.contains(speaker), "Continuation rows keep their clock without repeating the speaker")
            }
        }
        expectExportShape(output)
    }
}
