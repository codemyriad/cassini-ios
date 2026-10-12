import Testing
@testable import CassiniNotebook

struct VttWriterTests {
    // ports: VttWriterTest#oneSpeakerHasNoVoiceSpan
    @Test func oneSpeakerHasNoVoiceSpan() {
        let words = said("spk_0", 1_000, "Prova uno due tre.")
        expectExport("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nProva uno due tre.\n", VttWriter.write(transcript(words)))
    }

    // ports: VttWriterTest#manySpeakersWrapEveryCue
    @Test func manySpeakersWrapEveryCue() {
        let words = said("spk_0", 0, "Allora, la consegna slitta?")
            + said("spk_1", 1_800, "Sì, a giovedì.")
            + said("spk_1", 4_400, "Il camion è già partito.")
        expectExport("""
            WEBVTT

            00:00:00.000 --> 00:00:01.500
            <v Paolo>Allora, la consegna slitta?</v>

            00:00:01.800 --> 00:00:02.900
            <v Speaker 2>Sì, a giovedì.</v>

            00:00:04.400 --> 00:00:06.300
            <v Speaker 2>Il camion è già partito.</v>

            """, VttWriter.write(transcript(words)))
    }

    // ports: VttWriterTest#twoLinesStayInsideOneSpan
    @Test func twoLinesStayInsideOneSpan() {
        let words = said("spk_0", 0, "Abbiamo deciso che la data è giusta, ma prima di chiudere", stepMs: 300)
            + said("spk_1", 4_000, "Ok")
        expectExport("WEBVTT\n\n00:00:00.000 --> 00:00:03.200\n<v Paolo>Abbiamo deciso che la data è\ngiusta, ma prima di chiudere</v>\n\n"
                     + "00:00:04.000 --> 00:00:05.000\n<v Speaker 2>Ok</v>\n", VttWriter.write(transcript(words)))
    }

    // ports: VttWriterTest#textAndLabelsAreEscaped
    @Test func textAndLabelsAreEscaped() {
        let words = [w("a", 0, 400, "x<y"), w("a", 400, 800, "&"), w("a", 800, 1200, "z>w"), w("b", 2000, 2400, "ok")]
        let labels = ["a": "Anna --> <b>&\u{0007}\n", "b": "Bruno"]
        expectExport("WEBVTT\n\n00:00:00.000 --> 00:00:01.200\n<v Anna --&gt; &lt;b&gt;&amp;>x&lt;y &amp; z&gt;w</v>\n\n"
                     + "00:00:02.000 --> 00:00:03.000\n<v Bruno>ok</v>\n", VttWriter.write(transcript(words, labels: labels)))
    }

    // ports: VttWriterTest#emptyTranscriptIsTheHeaderOnly
    @Test func emptyTranscriptIsTheHeaderOnly() {
        expectExport("WEBVTT\n", VttWriter.write(transcript([])))
    }
}
