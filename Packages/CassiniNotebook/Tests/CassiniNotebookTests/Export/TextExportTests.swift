import Testing
@testable import CassiniNotebook

struct TextExportTests {
    private let subtitle = "8 Oct 2026, 15:10 · 23:50 · 3 speakers"

    // ports: TextExportTest#manySpeakersWithItalianAccents
    @Test func manySpeakersWithItalianAccents() {
        let words = said("spk_0", 0, "Allora, la consegna slitta a giovedì?")
            + said("spk_1", 3_000, "Sì, perché il camion è già partito.")
            + said("spk_2", 161_500, "D'accordo, però il prezzo resta quello dell'ordine di marzo.")
            + said("spk_0", 170_000, "Perfetto.")
        expectExport("""
            Chiamata con il fornitore
            8 Oct 2026, 15:10 · 23:50 · 3 speakers

            [00:00] Paolo
            Allora, la consegna slitta a giovedì?

            [00:03] Speaker 2
            Sì, perché il camion è già partito.

            [02:41] Élodie
            D'accordo, però il prezzo resta quello dell'ordine di marzo.

            [02:50] Paolo
            Perfetto.

            """, TextExport.write(transcript(words), subtitle: subtitle, emptyText: "No speech in this recording."))
    }

    // ports: TextExportTest#oneSpeakerLeavesTheLabelOut
    @Test func oneSpeakerLeavesTheLabelOut() {
        let words = said("spk_1", 1_000, "Prova uno due tre.")
        expectExport("Prova\n8 Oct 2026, 15:10 · 00:04\n\n[00:01]\nProva uno due tre.\n",
                     TextExport.write(transcript(words, title: "Prova"), subtitle: "8 Oct 2026, 15:10 · 00:04", emptyText: "No speech."))
    }

    // ports: TextExportTest#emptyTranscriptWritesTheEmptyText
    @Test func emptyTranscriptWritesTheEmptyText() {
        expectExport("Prova\n8 Oct 2026, 15:10 · 00:04\n\nNo speech in this recording.\n",
                     TextExport.write(transcript([], title: "Prova"), subtitle: "8 Oct 2026, 15:10 · 00:04",
                                      emptyText: "No speech in this recording."))
    }

    // ports: TextExportTest#clockFromOneHourAndAMissingLabelUsesTheId
    @Test func clockFromOneHourAndAMissingLabelUsesTheId() {
        let words = said("spk_0", 5_000, "Iniziamo.") + said("spk_9", 3_725_000, "Ultima cosa.")
        expectExport("Riunione\nsub\n\n[0:00:05] Paolo\nIniziamo.\n\n[1:02:05] spk_9\nUltima cosa.\n",
                     TextExport.write(transcript(words, durationMs: 3_800_000, title: "Riunione"), subtitle: "sub", emptyText: "-"))
    }

    // ports: TextExportTest#overlappingSpeakersKeepCanonicalOrder
    @Test func overlappingSpeakersKeepCanonicalOrder() {
        // The second turn starts before the first one ends; the text follows the canonical word order.
        let words = said("spk_0", 10_000, "Io direi di sì") + said("spk_1", 10_500, "No aspetta")
        expectExport("T\ns\n\n[00:10] Paolo\nIo direi di sì\n\n[00:10] Speaker 2\nNo aspetta\n",
                     TextExport.write(transcript(words, title: "T"), subtitle: "s", emptyText: "-"))
    }
}
