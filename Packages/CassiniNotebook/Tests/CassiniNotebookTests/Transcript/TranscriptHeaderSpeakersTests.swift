import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct TranscriptHeaderSpeakersTests {
    @Test func headerIncludesTheAutomaticallyNamedChipOnlySpeaker() throws {
        struct Fixture: Decodable {
            var items: [Item]
            struct Item: Decodable { var speaker: String?; var startMs: Int64; var endMs: Int64; var text: String }
        }
        let url = try #require(Bundle.module.url(forResource: "acknowledgment.words", withExtension: "json", subdirectory: "interjections"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let transcript = NoteTranscripts.draft(fixture.items.map {
            DraftWord(speaker: $0.speaker ?? "", startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        }, tentativeFromMs: nil, labels: ["ada": "Ada", "ben": "Ben"], automatic: ["ben"])
        let host = try #require(transcript.turns.first)
        let chip = try #require(host.interjections.first)
        #expect(transcript.turns.count == 1)
        #expect(host.speakerID == "ada")
        #expect(chip.speakerID == "ben")
        #expect(chip.auto)
        #expect(transcript.speakers == ["ada", "ben"])
        #expect(transcript.headerSpeakers == [
            TranscriptSpeaker(id: "ada", name: .named("Ada"), tint: host.tint, auto: false),
            TranscriptSpeaker(id: "ben", name: .named("Ben"), tint: chip.tint, auto: true)
        ])
    }

    @Test func headerOrderUsesCanonicalWordsRatherThanTurnDisplayOrAudioOrder() {
        let turns = [
            turn("a", speakerID: "a", name: .named("Alex"), tint: .blue, indices: [2, 4]),
            turn("b", speakerID: "b", name: .named("Ben"), tint: .violet, indices: [0, 3], auto: true),
            turn("c", speakerID: "c", name: .placeholder(3, label: "Speaker 3"), tint: .blue, indices: [1])
        ]
        let transcript = NoteTranscript(turns: turns)
        #expect(transcript.turns.map(\.id) == ["a", "b", "c"])
        #expect(transcript.speakers == ["b", "c", "a"])
        #expect(transcript.headerSpeakers == [
            TranscriptSpeaker(id: "b", name: .named("Ben"), tint: .violet, auto: true),
            TranscriptSpeaker(id: "c", name: .placeholder(3, label: "Speaker 3"), tint: .blue, auto: false),
            TranscriptSpeaker(id: "a", name: .named("Alex"), tint: .blue, auto: false)
        ])
    }

    @Test func equalSourceIndicesRetainEncounterOrderAtEachSpeakersMinimum() {
        let transcript = NoteTranscript(turns: [
            turn("late-a", speakerID: "a", name: .named("Alex"), tint: .blue, indices: [10]),
            turn("b", speakerID: "b", name: .named("Ben"), tint: .violet, indices: [0]),
            turn("early-a", speakerID: "a", name: .named("Alex"), tint: .blue, indices: [0]),
            turn("c", speakerID: "c", name: .named("Casey"), tint: .blue, indices: [0]),
            turn("duplicate-b", speakerID: "b", name: .named("Ben"), tint: .violet, indices: [0])
        ])
        #expect(transcript.speakers == ["b", "a", "c"])
        #expect(transcript.headerSpeakers.map(\.id) == ["b", "a", "c"])
    }

    @Test func headerExcludesUnknownAndAbsentIdentitiesWithoutChangingTheExistingIDList() {
        let transcript = NoteTranscript(turns: [
            turn("none", speakerID: nil, name: .unknown, tint: .blue, indices: [0]),
            turn("unknown", speakerID: "unknown", name: .unknown, tint: .blue, indices: [1]),
            turn("empty", speakerID: "", name: .named("Empty"), tint: .blue, indices: [2]),
            turn("blank", speakerID: "  ", name: .named("Blank"), tint: .blue, indices: [3]),
            turn("person", speakerID: "person", name: .placeholder(1, label: "Speaker 1"), tint: .blue, indices: [4])
        ])
        #expect(transcript.speakers == ["unknown", "", "  ", "person"])
        #expect(transcript.headerSpeakers == [
            TranscriptSpeaker(id: "person", name: .placeholder(1, label: "Speaker 1"), tint: .blue, auto: false)
        ])
        #expect(NoteTranscript.empty.speakers.isEmpty)
        #expect(NoteTranscript.empty.headerSpeakers.isEmpty)
    }

    /// Deliberately separate source indices from displayed row order, as D84 rejoining does.
    private func turn(_ id: String, speakerID: String?, name: SpeakerName, tint: SpeakerTint,
                      indices: [Int], auto: Bool = false) -> NoteTurn {
        let source = (0...indices.max()!).map { index in
            TranscriptWord(speaker: speakerID, start: Double(100 - index), end: Double(101 - index), text: "word\(index)")
        }
        let member = TurnModel.Member(kind: .words, wordIndices: indices,
                                      text: indices.map { source[$0].text }.joined(separator: " "))
        let row = TurnModel.Row(speaker: speakerID, continuation: false, startMs: 0, endMs: 200_000,
                                over: [], crosstalk: false, members: [member])
        return NoteTurn(id: id, speakerID: speakerID, name: name, tint: tint, start: 0, auto: auto,
                        source: source, row: row, over: [], suggestion: nil, inlineSuggestions: [], passages: []) { _ in
            (name, tint)
        }
    }
}
