import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

struct SpeakerColourPersistenceTests {
    private func note() -> Note {
        TranscriptFixtures.note([.init("u", 0, 500, "First."), .init("a", 600, 1000, "Second."),
                                 .init("b", 1100, 1500, "Third.")],
                                speakers: [.init(id: "u", name: "Speaker 1"), .init(id: "a", name: "Alex"),
                                           .init(id: "b", name: "Ben")])
    }

    @Test func legacyDecodeBackfillsAllFirstSpeechSlotsAndRoundTripsThem() throws {
        var original = note()
        // Catalog order is not speech order.
        original.speakers?.reverse()
        let migrated = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(original))
        #expect(migrated.speaker("u")?.colourIndex == 0)
        #expect(migrated.speaker("a")?.colourIndex == 1)
        #expect(migrated.speaker("b")?.colourIndex == 2)
        let reloaded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(migrated))
        #expect(reloaded.speakers == migrated.speakers)
        #expect(NoteTranscripts.sealed(reloaded).speakerTints == ["u": .stone, "a": .magenta, "b": .cyan])
    }

    @Test func legacySpeakerNamesInferProvenanceButExplicitUserProvenanceWins() throws {
        let legacy = try JSONDecoder().decode(NoteSpeaker.self, from: Data(#"{"id":"u","name":"Speaker 1"}"#.utf8))
        #expect(legacy.provenance == .unnamed && legacy.colourIndex == nil)
        let explicit = try JSONDecoder().decode(NoteSpeaker.self,
            from: Data(#"{"id":"u","name":"Speaker 1","colourIndex":5,"provenance":"user"}"#.utf8))
        #expect(explicit.provenance == .user && SpeakerTint.of(explicit) == .slate)
    }

    @Test func namingRevealsTheReservedSlotWithoutChangingOtherSpeakers() throws {
        var note = note()
        note.migrateSpeakers()
        note.renameSpeaker("u", name: "Speaker 1")
        #expect(note.speaker("u")?.provenance == .user)
        #expect(note.speaker("u")?.colourIndex == 0)
        let reloaded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        let transcript = NoteTranscripts.sealed(reloaded)
        #expect(transcript.speakerTints == ["u": .blue, "a": .magenta, "b": .cyan])
        #expect(transcript.turns.first?.name == .named("Speaker 1"))
        let input = try #require(NamingInput.of(reloaded, speakerID: "u", print: nil, voices: [],
                                               voicesReadOnly: false, voiceModelReady: false))
        #expect(input.namedLabel == "Speaker 1")
        #expect(input.speakerTints == transcript.speakerTints)
        let explicitlyNamed = try #require(reloaded.speaker("u"))
        #expect(![explicitlyNamed].isOneVoice)
    }

    @Test func mergePreservesTargetAndUnrelatedSlotsAndHistoricalVersion() throws {
        var note = note()
        note.migrateSpeakers()
        note.mergeSpeaker("u", into: "b", stamp: .init(date: Date(timeIntervalSince1970: 1)))
        #expect(note.speaker("b")?.colourIndex == 2)
        #expect(note.speaker("a")?.colourIndex == 1)
        #expect(NoteTranscripts.sealed(note).speakerTints["b"] == .cyan)
        let before = try #require(note.versions?.first(where: { $0.speakers.contains { $0.id == "u" } }))
        #expect(before.speakers.first { $0.id == "b" }?.colourIndex == 2)
        let reloaded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(reloaded.versions == note.versions)
    }

    @Test func legacyHistoricalSpeechBackfillsTheOriginalIdentityBeforeItsMergedPosition() {
        var note = note()
        note.saveCurrentVersion(.transcription)
        note.transcript[0].speakerID = "b"
        note.speakers?.removeAll { $0.id == "u" }
        note.backfillSpeakerColours()
        #expect(note.speaker("b")?.colourIndex == 2)
        #expect(note.versions?.first?.speakers.first { $0.id == "u" }?.colourIndex == 0)
    }

    @Test func storedSlotsIgnoreCurrentOrderAndNamesAndWrapAtSix() {
        let speakers = [NoteSpeaker(id: "a", name: "Alex", colourIndex: 7),
                        NoteSpeaker(id: "u", name: "Speaker 1", colourIndex: 0, provenance: .unnamed),
                        NoteSpeaker(id: "b", name: "Ben", colourIndex: 12)]
        #expect(SpeakerTint.assign(["b", "a", "u"], speakers: speakers)
                == ["a": .magenta, "u": .stone, "b": .blue])
        let filled = Note.assignColourIndices(speakers, order: ["b", "u", "a"])
        #expect(filled == speakers)
    }

    @Test func knownSpeakerSlotsSurviveReanalysisAndNewSpeakersAppend() {
        var note = note()
        note.migrateSpeakers()
        let turns = [SpeakerTurn(speakerID: "b", start: 0, end: 0.5),
                     SpeakerTurn(speakerID: "a", start: 0.6, end: 1),
                     SpeakerTurn(speakerID: "new", start: 1.1, end: 1.5)]
        note.applySpeakerAnalysis(turns: turns, matches: [:], voiceNames: [:], autoName: false,
                                  stamp: .init(date: Date(timeIntervalSince1970: 1)))
        #expect(note.speaker("b")?.colourIndex == 2)
        #expect(note.speaker("a")?.colourIndex == 1)
        #expect(note.speaker("new")?.colourIndex == 3)
    }
    @Test func portableRoundTripKeepsGappedSlotsAndNamingRevealsTheSameSlot() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.opus")
        let first = folder.appendingPathComponent("first.opus")
        let second = folder.appendingPathComponent("second.opus")
        try Data(PortableFixtures.silence(packets: 100)).write(to: audio)
        var note = note()
        note.speakers?[0].colourIndex = 5
        note.speakers?[1].colourIndex = 8
        note.speakers?[2].colourIndex = 13
        try PortableTranscript.export(note: note, opus: audio, destination: first, unassignedLabel: "Unknown speaker")
        let imported = try #require(PortableTranscript.read(from: first))
        #expect(imported.state == .ok)
        #expect(imported.speakers.map(\.colourIndex) == [5, 8, 13])
        #expect(imported.speakers.first?.provenance == .unnamed)
        note.transcript = imported.segments
        note.speakers = imported.speakers
        note.renameSpeaker("u", name: "Speaker 1")
        try PortableTranscript.export(note: note, opus: first, destination: second, unassignedLabel: "Unknown speaker")
        let reimported = try #require(PortableTranscript.read(from: second))
        #expect(reimported.state == .ok)
        #expect(reimported.speakers.map(\.colourIndex) == [5, 8, 13])
        #expect(reimported.speakers.first?.provenance == .user)
        #expect(reimported.speakers.first?.name == "Speaker 1")
        #expect(reimported.speakers.map { SpeakerTint.of($0) } == [.slate, .cyan, .magenta])
        let roster = try #require(CassiniDocument.read(second).manifest?["speakers"]?.array)
        #expect(try roster.first?.object?.number("colourIndex") == 5)
    }

    @Test func malformedPortableDisplayHintsAreIgnoredWithoutRejectingTheDocument() throws {
        let words = Transcript([Word("u", 0, 500, "First"), Word("a", 500, 900, "Second")], language: "en")
        let bytes = try CassiniDocument.create(PortableFixtures.silence(), transcript: words, title: "Hints",
            processing: JSONObject(), speakerLabels: ["u": "Speaker 1", "a": "Alex"],
            speakerHints: ["u": JSONObject([("colourIndex", .bool(true)), ("provenance", .string("unknown"))]),
                           "a": JSONObject([("colourIndex", .int(-1)), ("provenance", .int(3))])])
        let imported = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        #expect(imported.state == .ok)
        #expect(imported.speakers.map(\.colourIndex) == [0, 1])
        #expect(imported.speakers.map(\.provenance) == [.unnamed, .user])
    }

}
