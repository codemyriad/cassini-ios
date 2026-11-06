import Testing
@testable import CassiniNotebook

struct VttWriterTests {
    // ports: VttWriterTest#oneSpeakerHasNoVoiceSpan
    @Test func oneSpeakerHasNoVoiceSpan() {
        let words = said("spk_0", 1_000, "Testing one two three.")
        expectExport("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nTesting one two three.\n", VttWriter.write(transcript(words)))
    }

    // ports: VttWriterTest#manySpeakersWrapEveryCue
    @Test func manySpeakersWrapEveryCue() {
        let words = said("spk_0", 0, "So, is the delivery late?")
            + said("spk_1", 1_800, "Yes, on Thursday.")
            + said("spk_1", 4_400, "The truck has already left.")
        expectExport("""
            WEBVTT

            00:00:00.000 --> 00:00:01.900
            <v Paolo>So, is the delivery late?</v>

            00:00:01.800 --> 00:00:02.900
            <v Speaker 2>Yes, on Thursday.</v>

            00:00:04.400 --> 00:00:06.300
            <v Speaker 2>The truck has already left.</v>

            """, VttWriter.write(transcript(words)))
    }

    // ports: VttWriterTest#twoLinesStayInsideOneSpan
    @Test func twoLinesStayInsideOneSpan() {
        let words = said("spk_0", 0, "We agreed that the date is right, but before closing", stepMs: 300)
            + said("spk_1", 4_000, "Ok")
        expectExport("WEBVTT\n\n00:00:00.000 --> 00:00:02.900\n<v Paolo>We agreed that the date is\nright, but before closing</v>\n\n"
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
