import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

struct PortableSpeakerIdentityTests {
    private let composed = "voice-\u{E9}"
    private let decomposed = "voice-e\u{301}"

    @Test func bothByteDistinctSpeakersSurviveFreshSealReloadNamingAndExport() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("English audio.opus")
        let first = folder.appendingPathComponent("English first.opus")
        let second = folder.appendingPathComponent("English second.opus")
        try Data(PortableFixtures.silence()).write(to: plain)
        var note = TranscriptFixtures.note([
            .init(composed, 0, 20, "Hello"), .init(decomposed, 20, 40, "Hi")
        ], speakers: [
            .init(id: composed, name: "Alex", colourIndex: 2, provenance: .user),
            .init(id: decomposed, name: "Casey", colourIndex: 8, provenance: .source)
        ])
        #expect(note.transcript.count == 2, "The fixture must preserve the byte-distinct source segments before export")
        #expect(note.transcript.compactMap(\.speakerID).map { Data($0.utf8) } == ids)
        try PortableTranscript.export(note: note, opus: plain, destination: first, unassignedLabel: "Unknown speaker")
        let imported = try assertDocument(CassiniDocument.read(first), names: ["Alex", "Casey"], slots: [2, 8],
                                          provenance: [.user, .source])
        note.transcript = imported.segments; note.speakers = imported.speakers
        note = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(note.speakers?.count == 2)
        #expect(SpeakerStats.of(note.transcript).map { Data($0.speakerID.utf8) } == ids)
        let input = try #require(NamingInput.of(note, speakerID: decomposed, print: nil, voices: [],
                                               voicesReadOnly: false, voiceModelReady: true))
        #expect(input.label == "Casey")
        #expect(input.colourIndex == 8)
        #expect(input.mergeTargets.map { Data($0.speakerID.utf8) } == [Data(composed.utf8)])
        #expect(input.speakerTint(for: composed) == SpeakerTint.named(2))
        #expect(input.speakerTint(for: decomposed) == SpeakerTint.named(8))
        let shown = NoteTranscripts.sealed(note)
        #expect(shown.speakers.map { Data($0.utf8) } == ids)
        #expect(shown.turns.compactMap(\.speakerID).map { Data($0.utf8) } == ids)
        #expect(shown.turns.map(\.name) == [.named("Alex"), .named("Casey")])
        #expect(shown.speakerTint(for: composed) == SpeakerTint.named(2))
        #expect(shown.speakerTint(for: decomposed) == SpeakerTint.named(8))
        let text = ExportTranscript(note: note, unassignedLabel: "Unknown speaker")
        #expect(text.speakerCount == 2)
        #expect(text.label(composed) == "Alex")
        #expect(text.label(decomposed) == "Casey")
        let written = TextExport.write(text, subtitle: "English conversation", emptyText: "No words")
        #expect(written.contains("Alex"))
        #expect(written.contains("Casey"))
        #expect(SubtitleCues.build(text, labelPrefixForSrt: true).map(\.label) == ["Alex", "Casey"])
        note.renameSpeaker(decomposed, name: "Jordan")
        #expect(note.speakers?.map(\.name) == ["Alex", "Jordan"])
        #expect(note.transcript.map(\.speaker) == ["Alex", "Jordan"])
        #expect(note.speakers?.map(\.colourIndex) == [2, 8])
        try PortableTranscript.export(note: note, opus: first, destination: second, unassignedLabel: "Unknown speaker")
        _ = try assertDocument(CassiniDocument.read(second), names: ["Alex", "Jordan"], slots: [2, 8],
                               provenance: [.user, .user])
    }

    @Test func partialHintsReserveSlotsBeforeAllocatingLegacyIdentities() throws {
        let words = Transcript([Word("b", 0, 20, "Hello"), Word("x", 20, 40, "Hi")], language: "en")
        let bytes = try CassiniDocument.create(PortableFixtures.silence(), transcript: words,
            title: "English conversation", processing: JSONObject(), speakerHints: ["b": JSONObject([("colourIndex", .int(1))])])
        let imported = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        #expect(imported.speakers.map(\.id) == ["b", "x"])
        #expect(imported.speakers.map(\.colourIndex) == [1, 2])
        #expect(imported.segments.count == 2)
        #expect(imported.segments.flatMap(\.words).map(\.text) == ["Hello", "Hi"])
    }

    @Test func legacyVariantsShareOnePaletteStartingWithTheFirstReadableVariant() throws {
        let first = try CassiniDocument.create(PortableFixtures.silence(),
            transcript: Transcript([Word("a", 0, 10, "One"), Word("b", 10, 20, "Two"), Word("c", 20, 30, "Three")], language: "en"),
            title: "English conversation", processing: JSONObject())
        let second = try CassiniDocument.create(first,
            transcript: Transcript([Word("b", 0, 20, "Combined"), Word("c", 20, 30, "Three")], language: "en"),
            title: "English conversation", processing: JSONObject(), existing: CassiniDocument.read(first))
        let imported = try #require(PortableTranscript(CassiniDocument.read(second)))
        #expect(imported.versions.count == 2)
        #expect(imported.versions.map { $0.speakers.map(\.id) } == [["a", "b", "c"], ["b", "c"]])
        #expect(imported.versions.map { $0.speakers.map(\.colourIndex) } == [[0, 1, 2], [1, 2]])
        #expect(imported.speakers.map(\.id) == ["b", "c"])
        #expect(imported.speakers.map(\.colourIndex) == [1, 2])
        #expect(imported.versions.map { $0.segments.flatMap(\.words).map(\.text) } == [["One", "Two", "Three"], ["Combined", "Three"]])
    }

    @Test func viewerProjectionPreservesTokenLikeIDsNilAndTheLiteralUnknownSpeaker() {
        let identities: [String?] = [composed, decomposed, "__cassini_byte_speaker_0", nil, "Unknown speaker"]
        let words = identities.enumerated().map { index, id in
            TranscriptWord(speaker: id, start: Double(index), end: Double(index) + 0.1, text: "word\(index)")
        }
        let rows = TranscriptTurns.rows(of: words)
        #expect(rows.map { $0.speaker.map { Data($0.utf8) } } == identities.map { $0.map { Data($0.utf8) } })
        #expect(rows.flatMap(\.members).flatMap(\.wordIndices).sorted() == Array(words.indices))
        #expect(rows.flatMap(\.members).map(\.text) == words.map(\.text))
        #expect(SpeakerColourOrder.words(words).map { Data($0.utf8) } == identities.compactMap { $0.map { Data($0.utf8) } })
    }

    private var ids: [Data] { [Data(composed.utf8), Data(decomposed.utf8)] }

    private func assertDocument(_ document: CassiniDocument, names: [String], slots: [Int],
                                provenance: [NoteSpeaker.Provenance]) throws -> PortableTranscript {
        #expect(document.state == .ok)
        let imported = try #require(PortableTranscript(document))
        #expect(imported.speakers.count == 2)
        #expect(imported.speakers.map(\.byteID) == ids)
        #expect(imported.speakers.map(\.name) == names)
        #expect(imported.speakers.map(\.colourIndex) == slots.map(Optional.some))
        #expect(imported.speakers.map(\.provenance) == provenance)
        #expect(imported.segments.count == 2)
        #expect(imported.segments.compactMap(\.speakerID).map { Data($0.utf8) } == ids)
        #expect(imported.segments.map(\.speaker) == names.map(Optional.some))
        #expect(imported.segments.flatMap(\.words).map(\.text) == ["Hello", "Hi"])
        for variant in document.variants {
            let words = try #require(variant.transcript?.words)
            #expect(words.map { Data($0.speaker.utf8) } == ids)
            #expect(words.map(\.text) == ["Hello", "Hi"])
        }
        let roster = try #require(document.manifest?["speakers"]?.array)
        #expect(roster.count == 2)
        for index in ids.indices {
            let entry = try #require(roster.compactMap(\.object).first { $0["id"]?.string.map { Data($0.utf8) } == ids[index] })
            #expect(entry["label"]?.string == names[index])
            #expect(try entry.number("colourIndex") == Int64(slots[index]))
            #expect(entry["provenance"]?.string == provenance[index].rawValue)
        }
        return imported
    }
}
