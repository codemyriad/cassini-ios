import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

struct PortableRelabelProvenanceTests {
    @Test(arguments: ["Alex", "Speaker 1"])
    func anExplicitRelabelRevealsTheReservedColourAndSurvivesPortableImport(_ name: String) throws {
        let words = Transcript([Word("s", 0, 20, "Hello"), Word("s", 20, 40, "again")], language: "en")
        let initial = try CassiniDocument.create(PortableFixtures.silence(), transcript: words,
            title: "English conversation", processing: JSONObject(), speakerLabels: ["s": "Speaker 1"],
            speakerHints: ["s": JSONObject([("colourIndex", .int(4)), ("provenance", .string("unnamed"))])])
        var source = CassiniDocument.read(initial)
        var roster = try #require(source.manifest?["speakers"]?.array)
        var originalSpeaker = try #require(roster.first?.object)
        originalSpeaker["foreignHint"] = .string("keep this field")
        roster[0] = .object(originalSpeaker)
        source.manifest?["speakers"] = .array(roster)
        let inputBytes = try CassiniDocument.create(initial, transcript: words, title: "English conversation",
            processing: JSONObject(), existing: source)
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("English input.opus")
        let output = folder.appendingPathComponent("English renamed.opus")
        try Data(inputBytes).write(to: input)
        let before = CassiniDocument.read(input)
        let result = try CassiniDocument.relabel(input, existing: before, labels: ["s": " \(name) "], target: output)
        #expect(result.state == .ok)
        #expect(result.variants.map(\.id) == before.variants.map(\.id))
        #expect(result.variants.map(\.body) == before.variants.map(\.body))
        let savedSpeaker = try #require(result.manifest?["speakers"]?.array?.first?.object)
        #expect(savedSpeaker["label"]?.string == name)
        #expect(savedSpeaker["provenance"]?.string == "user")
        #expect(try savedSpeaker.number("colourIndex") == 4)
        #expect(savedSpeaker["foreignHint"]?.string == "keep this field")

        let imported = try #require(PortableTranscript.read(from: output))
        #expect(imported.speakers.count == 1)
        let speaker = try #require(imported.speakers.first)
        #expect(speaker.id == "s" && speaker.name == name)
        #expect(speaker.colourIndex == 4 && speaker.provenance == .user)
        #expect(SpeakerTint.of(speaker) == SpeakerTint.named(4))
        #expect(NamingInput(speakerID: speaker.id, label: speaker.name,
                            colourIndex: speaker.colourIndex, provenance: speaker.provenance).namedLabel == name)
        #expect(imported.segments.count == 1)
        #expect(imported.segments.first?.speakerID == "s")
        #expect(imported.segments.first?.words.map(\.text) == ["Hello", "again"])
        #expect(imported.segments.first?.words.map(\.start) == [0, 0.02])
        #expect(imported.segments.first?.words.map(\.end) == [0.02, 0.04])
        var note = Note(title: "English conversation")
        note.transcript = imported.segments
        note.speakers = imported.speakers
        let candidate = SpeakerSuggestion(speakerID: "s", label: "Speaker 1", voiceID: UUID(), voiceName: "Alex",
                                          score: 0.7, segmentID: note.transcript[0].id, start: 0)
        var unnamed = note
        unnamed.speakers = try #require(PortableTranscript(before)).speakers
        #expect(NoteTranscripts.sealed(unnamed, suggestions: [candidate]).turns.flatMap(\.allSuggestions).count == 1)
        let shown = NoteTranscripts.sealed(note, suggestions: [candidate])
        #expect(shown.turns.count == 1)
        #expect(shown.turns.first?.name == .named(name))
        #expect(shown.turns.first?.tint == SpeakerTint.named(4))
        #expect(shown.turns.flatMap(\.allSuggestions).isEmpty)
    }
}
