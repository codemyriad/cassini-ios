import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct TranscriptTurnsTests {
    private func w(_ speaker: String, _ startMs: Int, _ endMs: Int, _ text: String) -> TranscriptWord {
        TranscriptWord(speaker: speaker, start: Double(startMs) / 1000, end: Double(endMs) / 1000, text: text)
    }

    // ports: TranscriptTurnsTest#emptyTranscriptHasNoTurns
    @Test func anEmptyTranscriptHasNoTurns() {
        #expect(TranscriptTurns.of([]).isEmpty)
    }

    // ports: TranscriptTurnsTest#turnsAreMaximalRunsOfOneSpeaker
    @Test func turnsAreMaximalRunsOfOneSpeaker() {
        let turns = TranscriptTurns.of([
            w("a", 0, 300, "Yes,"), w("a", 400, 900, "sure."), w("b", 800, 1200, "Good."),
            w("a", 1500, 1900, "So"), w("a", 2000, 2400, "Thursday."),
        ])
        #expect(turns.map(\.speaker) == ["a", "b", "a"])
        #expect(turns.map(\.text) == ["Yes, sure.", "Good.", "So Thursday."])
        #expect(turns.map(\.start) == [0, 0.8, 1.5])
        #expect(turns.map(\.end) == [0.9, 1.2, 2.4])
    }

    // ports: TranscriptTurnsTest#aTurnEndsAtItsLastWordAndKeepsCanonicalOrder
    @Test func rowBoundsUseTheProducerEnvelopeAndKeepCanonicalWordIdentity() {
        let turn = TranscriptTurns.of([w("a", 1000, 3000, "long"), w("a", 900, 1500, "short")])
        #expect(turn.count == 1)
        // Like the viewer, row bounds use its member block envelope; audible bounds govern run joins internally.
        #expect(turn[0].start == 1.0)
        #expect(turn[0].end == 1.5)
        #expect(turn[0].text == "long short")
        #expect(turn[0].wordIndices == [0, 1])
    }

    /// D84: stored atoms and identity stay intact; the viewer supplies display spacing and never pairs quotes.
    @Test func passagesKeepStoredAtomsAndAPassageWithoutTimesIsOneLegacyAtom() {
        let timed = TranscriptSegment(text: "Hello world.", start: 0, end: 2, speakerID: "a", words: [
            TimedWord(text: "Hello", start: 0, end: 0.5), TimedWord(text: " world", start: 0.6, end: 1.2),
            TimedWord(text: ".", start: 1.2, end: 1.3),
        ])
        let trimmed = TranscriptSegment(text: "Hello to everyone", start: 2, end: 3, speakerID: "a", words: [
            TimedWord(text: "Hello", start: 2, end: 2.3), TimedWord(text: "to", start: 2.3, end: 2.4),
            TimedWord(text: "everyone", start: 2.4, end: 3),
        ])
        let plain = TranscriptSegment(text: "  An edited passage. ", start: 3, end: 5, speakerID: "b")
        let words = [timed, trimmed, plain].transcriptWords
        #expect(words.map(\.text) == ["Hello", "world", ".", "Hello", "to", "everyone", "An edited passage."])
        #expect(words.map(\.segmentID) == [timed.id, timed.id, timed.id, trimmed.id, trimmed.id, trimmed.id, plain.id])
        let turns = TranscriptTurns.of(words)
        #expect(turns.map(\.text) == ["Hello world. Hello to everyone", "An edited passage."])
        #expect(words.last?.start == 3)
        #expect(timed.words[1].text == " world", "The adapter never edits stored source data")
        #expect(plain.text == "  An edited passage. ")
    }
}

@Suite struct SpeakerTintTests {
    // ports: SpeakerTintTest#namedSpeakersCycleTheSixDecidedRoles
    @Test func namedSpeakersCycleTheSixDecidedRoles() {
        let order = ["a", "b", "c", "d", "e", "f", "g"]
        let tints = SpeakerTint.assign(order) { _ in false }
        #expect(order.map { tints[$0] } == [.blue, .magenta, .cyan, .orange, .violet, .slate, .blue])
    }

    // ports: SpeakerTintTest#placeholdersAreStoneAndReserveTheirSlot
    @Test func placeholdersAreStoneAndReserveTheirSlot() {
        let labels = ["s1": "Giulia", "s2": "Speaker 2", "s3": "Paolo Ferri", "s4": "Voce 4", "s5": "Anna"]
        let tints = SpeakerTint.assign(["s1", "s2", "s3", "s4", "s5"], labels: labels)
        #expect(tints == ["s1": .blue, "s2": .stone, "s3": .cyan, "s4": .stone, "s5": .violet])
    }

    // ports: SpeakerTintTest#aSpeakerWithoutALabelIsAPlaceholder
    @Test func aSpeakerWithoutALabelIsAPlaceholder() {
        let tints = SpeakerTint.assign(["s1", "s2"], labels: ["s2": "Luca"])
        #expect(tints["s1"] == .stone)
        #expect(tints["s2"] == .magenta)
    }

    // ports: SpeakerTintTest#theOrderIsTheGivenFirstTurnOrder
    @Test func theOrderIsTheGivenFirstTurnOrder() {
        let labels = ["a": "Anna", "b": "Bruno"]
        #expect(SpeakerTint.assign(["b", "a"], labels: labels)["b"] == .blue)
        #expect(SpeakerTint.assign(["b", "a"], labels: labels)["a"] == .magenta)
    }

    @Test func unnamedFirstSpeakerDoesNotShiftNamingOrMergeAvatarSlots() throws {
        let note = TranscriptFixtures.note([
            .init("u", 0, 500, "Yes."), .init("a", 600, 1000, "Welcome."), .init("b", 1100, 1500, "Agreed.")
        ], speakers: [.init(id: "u", name: "Speaker 1"), .init(id: "a", name: "Alex"), .init(id: "b", name: "Jamie")])
        let transcript = NoteTranscripts.sealed(note)
        #expect(transcript.speakerTints == ["u": .stone, "a": .magenta, "b": .cyan])
        for id in ["u", "a", "b"] {
            let input = try #require(NamingInput.of(note, speakerID: id, print: nil, voices: [],
                                                   voicesReadOnly: false, voiceModelReady: false))
            #expect(input.speakerTints == transcript.speakerTints)
        }
    }

    @Test func draftAndRenamedInputsUseTheSameCurrentLabelAssignment() throws {
        let input = NamingInput(speakerID: "a", label: "Alex", ordinal: 1,
                                mergeTargets: [.init(speakerID: "u", name: "Speaker 1", ordinal: 0, speakingTime: 1),
                                               .init(speakerID: "b", name: "Jamie", ordinal: 2, speakingTime: 1)], draft: true)
        let draft = NoteTranscripts.draft([.init(speaker: "u", startMs: 0, endMs: 500, text: "Yes."),
                                                  .init(speaker: "a", startMs: 600, endMs: 1000, text: "Welcome."),
                                                  .init(speaker: "b", startMs: 1100, endMs: 1500, text: "Agreed.")],
                                         tentativeFromMs: nil, labels: ["u": "Speaker 1", "a": "Alex", "b": "Jamie"])
        #expect(input.speakerTints == draft.speakerTints)
        var renamed = input
        renamed.mergeTargets[0].name = "Morgan"
        #expect(renamed.speakerTints == SpeakerTint.assign(["u", "a", "b"], labels: ["u": "Morgan", "a": "Alex", "b": "Jamie"]))
        #expect(renamed.speakerTints != input.speakerTints, "Current labels participate in the palette key")
    }

    // ports: SpeakerTintTest#theCycleWraps
    @Test func theCycleWraps() {
        #expect(SpeakerTint.named(0) == .blue)
        #expect(SpeakerTint.named(2) == .cyan)
        #expect(SpeakerTint.named(6) == .blue)
    }
}

/// Expected reading rows are copied unchanged from the viewer-generated D84 vector, rather than rebuilt by a test.
struct D84IntegrationVector {
    struct Expected: Decodable {
        struct Row: Decodable {
            struct Member: Decodable {
                var kind: String
                var speaker: String?
                var wordIndices: [Int]
                var text: String
            }
            var speaker: String?
            var continuation: Bool
            var startMs: Double
            var endMs: Double
            var over: [String]
            var crosstalk: Bool
            var members: [Member]
            var text: String {
                members.map { $0.kind == "interjection" ? "(\($0.speaker ?? "Unknown speaker"): \($0.text))" : $0.text }
                    .joined(separator: " ")
            }
        }
        var rows: [Row]
    }
    static let names = ["acknowledgment", "competing", "monologue", "overlapping-turns", "brief-reply", "seam-gap"]
    var words: [CassiniCore.Word]
    var rows: [Expected.Row]
    static func load(_ name: String) throws -> Self {
        let wordsURL = try #require(Bundle.module.url(forResource: name + ".words", withExtension: "json", subdirectory: "interjections"))
        let expectedURL = try #require(Bundle.module.url(forResource: name + ".expected", withExtension: "json", subdirectory: "interjections"))
        let words = try CassiniCore.Transcript.fromJSON(String(contentsOf: wordsURL, encoding: .utf8)).words
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: expectedURL))
        return Self(words: words, rows: expected.rows)
    }
}

extension TranscriptTurnsTests {
    @Test(arguments: D84IntegrationVector.names)
    func viewerRowsKeepCanonicalWordIdentityAcrossAllVectors(_ name: String) throws {
        let vector = try D84IntegrationVector.load(name)
        let words = vector.words.map { word in
            TranscriptWord(speaker: word.speaker, start: Double(word.startMs) / 1000,
                           end: Double(word.endMs) / 1000, text: word.text)
        }
        let turns = TranscriptTurns.of(words)
        #expect(turns.map(\.speaker) == vector.rows.map(\.speaker))
        #expect(turns.map(\.text) == vector.rows.map(\.text))
        #expect(turns.map(\.continuation) == vector.rows.map(\.continuation))
        #expect(turns.map(\.over) == vector.rows.map(\.over))
        #expect(turns.map(\.crosstalk) == vector.rows.map(\.crosstalk))
        #expect(turns.map(\.start) == vector.rows.map { $0.startMs / 1000 })
        #expect(turns.map(\.end) == vector.rows.map { $0.endMs / 1000 })
        #expect(turns.map(\.wordIndices) == vector.rows.map { $0.members.flatMap(\.wordIndices) })
        #expect(turns.flatMap(\.wordIndices).sorted() == Array(words.indices))
        for turn in turns {
            #expect(turn.words == turn.wordIndices.map { words[$0] }, "Playback identity uses source indices")
        }
    }
}

extension TranscriptTurnsTests {
    @Test func confidenceSurvivesPortableAtomsStorageDraftAndExports() throws {
        let words = [CassiniCore.Word("ada", 0, 500, "Maybe.", lowConfidenceSpeaker: true)]
        let segments = TranscriptSegment.segments(of: words)
        #expect(segments[0].words[0].text == "Maybe.", "New producer words carry no separator whitespace")
        #expect(segments[0].words[0].lowConfidenceSpeaker == true)
        let data = try JSONEncoder().encode(segments)
        let restored = try JSONDecoder().decode([TranscriptSegment].self, from: data)
        let atoms = restored.transcriptWords
        #expect(atoms[0].lowConfidenceSpeaker)
        #expect(TranscriptTurns.of(atoms)[0].crosstalk)
        #expect(restored[0].draftWords[0].lowConfidenceSpeaker == true)
        #expect(PreviewWord.of(restored[0])[0].lowConfidenceSpeaker)
        #expect(words[0].with(startMs: 100).lowConfidenceSpeaker)
        let shifted = WordGate.offsetDecoderWords([DecodedWord(words[0])], offsetMs: 100, headPaddingMs: 50)
        #expect(shifted[0].word.lowConfidenceSpeaker)
        #expect(shifted[0].word.startMs == 100)
        let assigned = Diarization.assign(words, turns: [DiarizerTurn(0, 500, 1)], prefix: "speaker-", stableIds: true)
        #expect(assigned[0].lowConfidenceSpeaker)
        #expect(assigned[0].speaker == "speaker-2")
        var note = Note(title: "Uncertain speaker")
        note.transcript = restored
        let export = ExportTranscript(note: note, unassignedLabel: "Unknown speaker")
        #expect(export.words == words)
        #expect(NoteTranscripts.sealed(note).turns[0].crosstalk)
        #expect(NoteTranscripts.draft(restored.flatMap(\.draftWords), tentativeFromMs: nil).turns[0].crosstalk)
        #expect(TextExport.write(export, subtitle: "sub", emptyText: "-").contains("(probably crosstalk)"))
    }

    @Test func legacyTimedWordsDecodeWithoutConfidenceAndBlankAtomsAreNotRendered() throws {
        let legacy = Data(#"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","text":"Hello","start":0,"end":1}"#.utf8)
        let decoded = try JSONDecoder().decode(TimedWord.self, from: legacy)
        #expect(decoded.lowConfidenceSpeaker == nil)
        let segment = TranscriptSegment(text: "Hello", start: 0, end: 1, words: [decoded, .init(text: " \n", start: 1, end: 1)])
        #expect([segment].transcriptWords.map(\.text) == ["Hello"])
        #expect(![segment].transcriptWords[0].lowConfidenceSpeaker)
    }
}
