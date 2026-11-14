import Foundation
import Testing
@testable import CassiniNotebook

struct TranscriptSpeakerByteIdentityTests {
    private let composed = "voice-\u{E9}"
    private let decomposed = "voice-e\u{301}"
    private var ids: [Data] { [Data(composed.utf8), Data(decomposed.utf8)] }

    @Test func sealedProducerKeepsEqualDisplayMetadataAsTwoDistinctSpeakers() {
        let note = TranscriptFixtures.note([
            .init(composed, 0, 100, "Hello"), .init(decomposed, 200, 300, "Hi")
        ], speakers: [
            NoteSpeaker(id: composed, name: "Alex", colourIndex: 0, provenance: .user),
            NoteSpeaker(id: decomposed, name: "Alex", colourIndex: 6, provenance: .user)
        ])
        let transcript = NoteTranscripts.sealed(note)
        #expect(transcript.headerSpeakers == [
            TranscriptSpeaker(id: composed, name: .named("Alex"), tint: .blue, auto: false),
            TranscriptSpeaker(id: decomposed, name: .named("Alex"), tint: .blue, auto: false)
        ])
        #expect(transcript.headerSpeakers.map(\.byteID) == ids)
        #expect(transcript.headerSpeakers[0] != transcript.headerSpeakers[1])
        #expect(Set(transcript.headerSpeakers).count == 2)
        #expect(Set(transcript.headerSpeakers + transcript.headerSpeakers).count == 2)
    }

    @Test func draftProducerKeepsChipOnlyIdentityWithTheSameNameTintAndAutomaticFlag() throws {
        struct Fixture: Decodable {
            var items: [Item]
            struct Item: Decodable { var speaker: String?; var startMs: Int64; var endMs: Int64; var text: String }
        }
        let url = try #require(Bundle.module.url(forResource: "acknowledgment.words", withExtension: "json", subdirectory: "interjections"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let words = fixture.items.map {
            DraftWord(speaker: $0.speaker == "ada" ? composed : decomposed,
                      startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        }
        let transcript = NoteTranscripts.draft(words, tentativeFromMs: nil,
            labelsByID: [ids[0]: "Alex", ids[1]: "Alex"], colourIndicesByID: [ids[0]: 0, ids[1]: 6],
            provenanceByID: [ids[0]: .user, ids[1]: .user], automaticByID: Set(ids))
        let host = try #require(transcript.turns.first)
        #expect(transcript.turns.count == 1)
        let hostID = try #require(host.speakerID)
        #expect(Data(hostID.utf8) == ids[0])
        #expect(transcript.headerSpeakers.map(\.byteID) == ids)
        #expect(transcript.headerSpeakers.map(\.name) == [.named("Alex"), .named("Alex")])
        #expect(transcript.headerSpeakers.map(\.tint) == [.blue, .blue])
        #expect(transcript.headerSpeakers.map(\.auto) == [true, true])
        #expect(Set(transcript.headerSpeakers).count == 2)
        let chips = host.inlineSpeakersForNaming(isDraft: true, renamable: true)
        #expect(chips.count == 1)
        #expect(chips.compactMap(\.speakerID).map { Data($0.utf8) } == [ids[1]])
        #expect(chips.map(\.name) == [.named("Alex")])
        #expect(chips.map(\.tint) == [.blue])
        #expect(chips.map(\.auto) == [true])
        #expect(host.inlineSpeakersForNaming(isDraft: false, renamable: true).isEmpty)
        #expect(host.inlineSpeakersForNaming(isDraft: true, renamable: false).isEmpty)
        #expect(transcript.turns.flatMap(\.words).map(\.sourceIndex).sorted() == Array(words.indices))
    }

    @Test func legacyDraftMapsOnlyNameTheirExactStoredIDAndAllocateTheOtherSlot() {
        let words = [DraftWord(speaker: composed, startMs: 0, endMs: 100, text: "Hello"),
                     DraftWord(speaker: decomposed, startMs: 200, endMs: 300, text: "Hi")]
        let transcript = NoteTranscripts.draft(words, tentativeFromMs: nil, labels: [composed: "Alex"],
            automatic: [composed], colourIndices: [composed: 2], provenance: [composed: .user])
        #expect(transcript.headerSpeakers.map(\.byteID) == ids)
        #expect(transcript.headerSpeakers.map(\.name) == [.named("Alex"), .placeholder(2, label: DefaultLabels.placeholder(2))])
        #expect(transcript.headerSpeakers.map(\.tint) == [.cyan, .stone])
        #expect(transcript.headerSpeakers.map(\.auto) == [true, false])
        let named = NoteTranscripts.draft(words, tentativeFromMs: nil,
            labelsByID: [ids[0]: "Alex", ids[1]: "Casey"], colourIndicesByID: [ids[0]: 2],
            provenanceByID: [ids[0]: .user, ids[1]: .user])
        #expect(named.headerSpeakers.map(\.tint) == [.cyan, .orange])
    }

    @Test func suggestionPlacementRetainsBothByteDistinctDraftSpeakers() {
        let words = [DraftWord(speaker: composed, startMs: 0, endMs: 100, text: "Hello"),
                     DraftWord(speaker: decomposed, startMs: 200, endMs: 300, text: "Hi")]
        let voice = UUID()
        let transcript = NoteTranscripts.draft(words, tentativeFromMs: nil, suggestions: [
            DraftSuggestion(speakerID: composed, voiceID: voice, name: "Alex", score: 0.8, atMs: 0),
            DraftSuggestion(speakerID: decomposed, voiceID: voice, name: "Alex", score: 0.8, atMs: 200)
        ])
        #expect(transcript.turns.flatMap(\.allSuggestions).map(\.byteSpeakerID) == ids)
        #expect(transcript.headerSpeakers.map(\.byteID) == ids)
        #expect(transcript.headerSpeakers.map(\.name) == [
            .placeholder(1, label: DefaultLabels.placeholder(1)), .placeholder(2, label: DefaultLabels.placeholder(2))
        ])
    }

    @Test func namingChoicesDeduplicateExactChipIDsWithoutMergingEquivalentOnes() {
        let identities = ["host", composed, decomposed, composed]
        let source = identities.enumerated().map { index, id in
            TranscriptWord(speaker: id, start: Double(index), end: Double(index) + 0.1, text: "word\(index)")
        }
        let members = identities.enumerated().map { index, id in
            TurnModel.Member(kind: index == 0 ? .words : .interjection, speaker: index == 0 ? nil : id,
                             wordIndices: [index], text: source[index].text)
        }
        let row = TurnModel.Row(speaker: "host", continuation: false, startMs: 0, endMs: 4000,
                                over: [], crosstalk: false, members: members)
        let turn = NoteTurn(id: "w0", speakerID: "host", name: .named("Alex"), tint: .blue, start: 0, auto: false,
                            source: source, row: row, over: [], suggestion: nil, inlineSuggestions: [], passages: []) { _ in
            (.named("Alex"), .blue)
        }
        let choices = turn.inlineSpeakersForNaming(isDraft: true, renamable: true)
        #expect(choices.count == 2)
        #expect(choices.compactMap(\.speakerID).map { Data($0.utf8) } == ids)
        #expect(choices.map(\.wordRange) == [1..<2, 2..<3])
    }

    @Test func namingSheetsUseExactIdentityEvenWhenTheirDraftsMatch() throws {
        let first = NoteSheet.naming(composed, draft: "Alex")
        let second = NoteSheet.naming(decomposed, draft: "Alex")
        #expect(first != second)
        #expect(first.id != second.id)
        #expect(Set([first, second, first]).count == 2)
        #expect(first == .naming(composed, draft: "Alex"))
        #expect(first != .naming(composed, draft: "Casey"))
        #expect(first.id == NoteSheet.naming(composed, draft: "Casey").id)
        #expect(try #require(NoteSheet(first.overlay, draft: first.draft, in: Note(title: "English conversation"))) == first)
        #expect(try #require(NoteSheet(second.overlay, draft: second.draft, in: Note(title: "English conversation"))) == second)
        #expect(NoteSheet.rename(draft: "Alex") == .rename(draft: "Alex"))
        #expect(NoteSheet.rename(draft: "Alex") != .rename(draft: "Casey"))
        #expect(Set([NoteSheet.speakers, .versions, .documentInfo]).count == 3)
    }
}
