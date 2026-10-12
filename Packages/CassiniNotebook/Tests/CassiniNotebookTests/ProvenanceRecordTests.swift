import Testing
import CassiniNotebook

@Suite struct ProvenanceRecordTests {
    private let words = [
        TranscriptSegment(text: "Hello there", start: 0, end: 2, words: [
            TimedWord(text: "Hello", start: 0, end: 0.8), TimedWord(text: " there", start: 1, end: 2),
        ]),
        TranscriptSegment(text: "Again", start: 3, end: 4, words: [TimedWord(text: "Again", start: 3, end: 4)]),
    ]
    private let provenance = TranscriptProvenance(language: "en-US", inferenceMs: 1_200, resumedFromMs: 0,
                                                  speakerDiarization: .init(model: "m", sha: nil, turnCount: 9, speakerCount: 9))

    @Test func theRecordDescribesTheWordsItWasMadeWith() {
        let record = ProvenanceRecord(provenance: provenance, transcript: words)
        #expect(record.provenance.speakerDiarization == nil, "the speaker record comes from the speaker step")
        #expect(record.provenance(for: words)?.inferenceMs == 1_200)
        var edited = words
        edited[1].text = "Again!"
        edited[1].words = []
        #expect(record.provenance(for: edited) == nil)
        #expect(record.provenance(for: [TranscriptSegment(text: "Imported", start: 0, end: 4)]) == nil)
        #expect(record.provenance(for: []) == nil)
    }

    @Test func theSpeakerRecordHoldsWhileTheSpeakersAreTheAnalysisOnes() {
        var record = ProvenanceRecord(provenance: provenance, transcript: words)
        let turns = [SpeakerTurn(speakerID: "x_a", start: 0, end: 0.9), SpeakerTurn(speakerID: "x_b", start: 0.9, end: 4)]
        let attributed = SpeakerAttribution.assign(words, turns: turns)
        #expect(attributed.count == 3, "the passages are split by speaker")
        let diarization = TranscriptProvenance.SpeakerDiarization(model: "m", sha: "s", turnCount: 2, speakerCount: 2)
        record.addSpeakers(diarization, transcript: attributed)
        #expect(record.provenance(for: attributed)?.speakerDiarization == diarization)

        // A merge keeps the analysis's ids.
        var merged = attributed
        for index in merged.indices { merged[index].speakerID = "x_a" }
        #expect(record.provenance(for: merged)?.speakerDiarization == diarization)
        // The words before the analysis, or speakers from somewhere else, keep the words' record only.
        #expect(record.provenance(for: words)?.speakerDiarization == nil)
        #expect(record.provenance(for: words)?.engine == TranscriptProvenance.appleSpeech)
        var other = attributed
        other[0].speakerID = "y_a"
        #expect(record.provenance(for: other)?.speakerDiarization == nil)
    }

    @Test func theFingerprintIgnoresPassagesAndSpeakersButNotTimes() {
        let joined = [TranscriptSegment(text: "Hello there Again", start: 0, end: 4, speakerID: "a",
                                        words: words.flatMap(\.words))]
        #expect(ProvenanceRecord.fingerprint(of: joined) == ProvenanceRecord.fingerprint(of: words))
        var shifted = words
        shifted[1].words[0].end = 4.5
        #expect(ProvenanceRecord.fingerprint(of: shifted) != ProvenanceRecord.fingerprint(of: words))
    }
}
