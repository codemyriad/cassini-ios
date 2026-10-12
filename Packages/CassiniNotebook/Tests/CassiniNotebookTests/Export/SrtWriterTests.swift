import Testing
@testable import CassiniNotebook

struct SrtWriterTests {
    // ports: SrtWriterTest#oneSpeakerHasNoPrefix
    @Test func oneSpeakerHasNoPrefix() {
        let words = said("spk_0", 1_000, "Prova uno due tre.")
        expectExport("1\n00:00:01,000 --> 00:00:02,500\nProva uno due tre.\n", SrtWriter.write(transcript(words)))
    }

    // ports: SrtWriterTest#manySpeakersArePrefixedOnChangeOnly
    @Test func manySpeakersArePrefixedOnChangeOnly() {
        let words = said("spk_0", 0, "Allora, la consegna slitta?")
            + said("spk_1", 1_800, "Sì, a giovedì.")
            + said("spk_1", 4_400, "Il camion è già partito.")
            + said("spk_2", 6_500, "Però il prezzo resta.")
        expectExport("""
            1
            00:00:00,000 --> 00:00:01,500
            Paolo: Allora, la consegna slitta?

            2
            00:00:01,800 --> 00:00:02,900
            Speaker 2: Sì, a giovedì.

            3
            00:00:04,400 --> 00:00:06,300
            Il camion è già partito.

            4
            00:00:06,500 --> 00:00:08,000
            Élodie: Però il prezzo resta.

            """, SrtWriter.write(transcript(words)))
    }

    // ports: SrtWriterTest#emptyTranscriptIsOneNewline
    @Test func emptyTranscriptIsOneNewline() {
        expectExport("\n", SrtWriter.write(transcript([])))
    }

    // ports: SrtWriterTest#textIsNotEscaped
    @Test func textIsNotEscaped() {
        let words = [w("spk_0", 0, 1500, "x<y"), w("spk_0", 1500, 1800, "&")]
        expectExport("1\n00:00:00,000 --> 00:00:01,800\nx<y &\n", SrtWriter.write(transcript(words)))
    }

    // ports: SrtWriterTest#clockBeyondOneHour
    @Test func clockBeyondOneHour() {
        let words = said("spk_0", 3_725_250, "Ultima cosa")
        expectExport("1\n01:02:05,250 --> 01:02:06,250\nUltima cosa\n", SrtWriter.write(transcript(words, durationMs: 3_800_000)))
    }
}
