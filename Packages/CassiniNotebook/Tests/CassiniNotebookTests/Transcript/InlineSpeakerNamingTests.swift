import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct InlineSpeakerNamingTests {
    @Test func chipOnlyDraftSpeakerCanBeNamedWithoutVoiceSuggestions() throws {
        struct Fixture: Decodable {
            var items: [Item]
            struct Item: Decodable { var speaker: String?; var startMs: Int64; var endMs: Int64; var text: String }
        }
        let url = try #require(Bundle.module.url(forResource: "acknowledgment.words", withExtension: "json", subdirectory: "interjections"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let transcript = NoteTranscripts.draft(fixture.items.map {
            DraftWord(speaker: $0.speaker ?? "", startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        }, tentativeFromMs: nil, labels: ["ada": "Ada", "ben": "Ben"])
        let host = try #require(transcript.turns.first)
        #expect(transcript.turns.count == 1)
        #expect(host.speakerID == "ada")
        #expect(host.suggestion == nil)
        #expect(host.inlineSuggestions.isEmpty)
        let available = host.inlineSpeakersForNaming(isDraft: true, renamable: true)
        #expect(available.map(\.speakerID) == ["ben"])
        #expect(available.first?.name == .named("Ben"))
        #expect(available.first?.tint == .teal)
        #expect(available == host.interjections)
        #expect(host.inlineSpeakersForNaming(isDraft: false, renamable: true).isEmpty)
        #expect(host.inlineSpeakersForNaming(isDraft: true, renamable: false).isEmpty)
        #expect(host.inlineSpeakersForNaming(isDraft: false, renamable: false).isEmpty)
    }

    @Test func namingChoicesExcludeUnnameableIdentitiesAndDeduplicateStably() {
        let specifications: [(String?, SpeakerName, SpeakerTint)] = [
            ("ben", .named("Benjamin"), .violet),
            ("ben", .named("Later duplicate"), .blue),
            (nil, .unknown, .amber),
            ("", .named("Empty identity"), .amber),
            ("  ", .named("Blank identity"), .amber),
            (NoteTranscripts.draftOneVoice, .placeholder(1, label: "Speaker 1"), .amber),
            ("ada", .named("Host duplicate"), .blue),
            ("Unknown speaker", .unknown, .amber),
            ("cy", .placeholder(3, label: "Speaker 3"), .amber)
        ]
        let source = [TranscriptWord(speaker: "ada", start: 0, end: 1, text: "Host")] + specifications.enumerated().map {
            TranscriptWord(speaker: $0.element.0, start: Double($0.offset + 1), end: Double($0.offset + 2), text: "Aside\($0.offset)")
        }
        let members = [TurnModel.Member(kind: .words, wordIndices: [0], text: "Host")] + specifications.enumerated().map {
            TurnModel.Member(kind: .interjection, speaker: $0.element.0, crosstalk: true,
                             wordIndices: [$0.offset + 1], text: "Aside\($0.offset)")
        }
        let row = TurnModel.Row(speaker: "ada", continuation: false, startMs: 0, endMs: 10_000,
                                over: [], crosstalk: false, members: members)
        let turn = NoteTurn(id: "w0", speakerID: "ada", name: .named("Ada"), tint: .blue, start: 0, auto: false,
                            source: source, row: row, over: [], suggestion: nil, inlineSuggestions: [], passages: []) { id in
            let spec = specifications.first { $0.0 == id }
            return (spec?.1 ?? .unknown, spec?.2 ?? .amber)
        }
        let choices = turn.inlineSpeakersForNaming(isDraft: true, renamable: true)
        #expect(choices.map(\.speakerID) == ["ben", "cy"])
        // Return the original first chip metadata, including its word/text ranges and confidence.
        #expect(choices == [turn.interjections[0], turn.interjections[8]])
        #expect(choices.map(\.name) == [.named("Benjamin"), .placeholder(3, label: "Speaker 3")])
        #expect(choices.map(\.tint) == [.violet, .amber])
        #expect(choices.allSatisfy { $0.crosstalk })
    }
}
