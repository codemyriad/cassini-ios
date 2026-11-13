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
    @Test func firstRealAnalysisReplacesBootstrapSlotZeroAndKnownReanalysisPreservesIt() {
        var note = note()
        let bootstrap = NoteSpeaker.oneVoice(prefix: "run_", language: "en")
        note.transcript = Note.oneVoice(note.transcript, bootstrap)
        note.speakers = [bootstrap]
        note.saveCurrentVersion(.transcription)
        note.applySpeakerAnalysis(turns: [.init(speakerID: "real-a", start: 0, end: 0.5),
                                          .init(speakerID: "real-b", start: 0.6, end: 1.5)],
                                  matches: [:], voiceNames: [:], autoName: false,
                                  stamp: .init(date: Date(timeIntervalSince1970: 1)))
        #expect(note.speaker("real-a")?.colourIndex == 0)
        #expect(note.speaker("real-b")?.colourIndex == 1)
        note.renameSpeaker("real-a", name: "Speaker 1")
        note.renameSpeaker("real-b", name: "Ben")
        note.applySpeakerAnalysis(turns: [.init(speakerID: "real-b", start: 0, end: 0.5),
                                          .init(speakerID: "real-a", start: 0.6, end: 1.5)],
                                  matches: [:], voiceNames: [:], autoName: false,
                                  stamp: .init(date: Date(timeIntervalSince1970: 2)))
        #expect(note.speaker("real-a")?.colourIndex == 0)
        #expect(note.speaker("real-a")?.provenance == .user)
        #expect(note.speaker("real-b")?.colourIndex == 1)
        #expect(NoteTranscripts.sealed(note).speakerTints == ["real-a": .blue, "real-b": .magenta])
    }

    @Test func uniqueAutomaticSavedVoiceIdentityCarriesTheSlotAcrossNewSpeakerIDs() {
        for fromHistory in [false, true] {
            var note = note()
            let voice = UUID()
            note.speakers?[1] = NoteSpeaker(id: "a", name: "Alex", match: .confirmed(voice: voice, score: 1), colourIndex: 8)
            note.backfillSpeakerColours()
            if fromHistory {
                note.saveCurrentVersion(.transcription)
                let bootstrap = NoteSpeaker.oneVoice(prefix: "again_", language: "en")
                note.transcript = Note.oneVoice(note.transcript, bootstrap)
                note.speakers = [bootstrap]
            }
            let links = note.carriedVoiceLinks
            note.applySpeakerAnalysis(turns: [.init(speakerID: "new-a", start: 0, end: 0.5),
                                              .init(speakerID: "new-person", start: 0.6, end: 1.5)],
                                      matches: ["new-a": .init(voiceID: voice, score: 1, automatic: true)],
                                      voiceNames: [voice: "Alex"], carriedLinks: links, autoName: false,
                                      stamp: .init(date: Date(timeIntervalSince1970: 1)))
            #expect(note.speaker("new-a")?.colourIndex == 8)
            #expect(note.speaker("new-a")?.name == "Alex")
            #expect(note.speaker("new-person")?.colourIndex == 11)
        }
    }

    @Test func suggestedOrAmbiguousSavedVoiceIdentityDoesNotRecycleAStoredSlot() {
        for automatic in [false, true] {
            var note = note()
            let voice = UUID()
            note.speakers?[1] = NoteSpeaker(id: "a", name: "Alex", match: .confirmed(voice: voice, score: 1), colourIndex: 8)
            if automatic {
                note.speakers?[2] = NoteSpeaker(id: "b", name: "Ben", match: .confirmed(voice: voice, score: 1), colourIndex: 9)
            }
            note.backfillSpeakerColours()
            let maximum = (note.speakers ?? []).compactMap(\.colourIndex).max() ?? -1
            note.applySpeakerAnalysis(turns: [.init(speakerID: "new", start: 0, end: 1.5)],
                                      matches: ["new": .init(voiceID: voice, score: 1, automatic: automatic)],
                                      voiceNames: [voice: "Alex"], carriedLinks: note.carriedVoiceLinks, autoName: false,
                                      stamp: .init(date: Date(timeIntervalSince1970: 1)))
            #expect(note.speaker("new")?.colourIndex == maximum + 1)
        }
    }

    @Test func namedProvenanceSurvivesPlaceholderLookingRenameButExplicitRejectionHidesTheSlot() {
        let voice = UUID()
        for provenance in [NoteSpeaker.Provenance.user, .recognised, .source] {
            var speaker = NoteSpeaker(id: "a", name: "Alex", colourIndex: 8, provenance: provenance)
            speaker.name = "Speaker 2"
            #expect(speaker.provenance == provenance)
            #expect(SpeakerTint.of(speaker) == .cyan)
        }
        var note = note()
        note.speakers?[1] = NoteSpeaker(id: "a", name: "Alex", match: .auto(voice: voice, score: 1),
                                       colourIndex: 8, provenance: .recognised)
        note.speakers?[1].name = "Speaker 2"
        note.applySpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 1.5)],
                                  matches: [:], voiceNames: [:], autoName: false,
                                  stamp: .init(date: Date(timeIntervalSince1970: 1)))
        #expect(note.speaker("a")?.provenance == .recognised)
        #expect(NoteTranscripts.sealed(note).speakerTints["a"] == .cyan)
        note.rejectVoice(voice, for: "a", restorePlaceholder: true)
        #expect(note.speaker("a")?.provenance == .unnamed)
        #expect(note.speaker("a")?.colourIndex == 8)
        #expect(NoteTranscripts.sealed(note).speakerTints["a"] == .stone)
    }

    @Test func everyActualNamingProducerMarksPlaceholderLookingNamesAsNamed() {
        let voice = UUID()
        for kind in 0..<3 {
            var note = note()
            let local: Set<UUID> = kind == 0 ? [voice] : []
            let confirmed: [UUID: VoiceMatchState] = kind == 1 ? [voice: .confirmed(voice: voice, score: 1)] : [:]
            note.applySpeakerAnalysis(turns: [.init(speakerID: "new", start: 0, end: 1.5)],
                matches: ["new": .init(voiceID: voice, score: 1, automatic: true)],
                voiceNames: [voice: "Speaker 2"], localVoices: local, carriedLinks: confirmed, autoName: true,
                stamp: .init(date: Date(timeIntervalSince1970: 1)))
            #expect(note.speaker("new")?.provenance == (kind == 2 ? .recognised : .user))
            #expect(note.speaker("new")?.name == "Speaker 2")
            #expect(NoteTranscripts.sealed(note).speakerTints["new"] != .stone)
        }
    }

    @Test func legacyDraftPlaceholderDoesNotReplaceAnAutomaticNameOrLink() {
        var note = note()
        let voice = UUID()
        note.applySpeakerAnalysis(turns: [.init(speakerID: "new", start: 0, end: 1.5)],
                                  matches: ["new": .init(voiceID: voice, score: 1, automatic: true)],
                                  voiceNames: [voice: "Alex"], autoName: true,
                                  stamp: .init(date: Date(timeIntervalSince1970: 1)), labels: ["new": "Speaker 1"])
        #expect(note.speaker("new")?.name == "Alex")
        #expect(note.speaker("new")?.linkedVoiceID == voice)
        #expect(note.speaker("new")?.provenance == .recognised)
        #expect(note.transcript.map(\.speaker) == ["Alex", "Alex", "Alex"])
    }

    @Test func missingSlotsUseEarliestTimedSpeechWithoutChangingCanonicalOrderOrNames() throws {
        var note = Note(title: "Unsorted")
        note.transcript = [.init(text: "A", start: 10, end: 11, speaker: "Alex", speakerID: "a"),
                           .init(text: "B", start: 0, end: 1, speaker: "Ben", speakerID: "b")]
        note.speakers = [.init(id: "a", name: "Alex"), .init(id: "b", name: "Ben")]
        let original = note.transcript
        let before = NoteTranscripts.sealed(note)
        note.backfillSpeakerColours()
        #expect(note.speaker("b")?.colourIndex == 0)
        #expect(note.speaker("a")?.colourIndex == 1)
        #expect(note.transcript == original)
        #expect(NoteTranscripts.sealed(note).turns.map(\.id) == before.turns.map(\.id))
        let input = try #require(NamingInput.of(note, speakerID: "a", print: nil, voices: [],
                                               voicesReadOnly: false, voiceModelReady: false))
        #expect(input.speakerTints == ["b": .blue, "a": .magenta])
        note.renameSpeaker("b", name: "Speaker 2")
        #expect(note.speaker("b")?.colourIndex == 0 && note.speaker("b")?.provenance == .user)
        note.transcript.reverse()
        note.backfillSpeakerColours()
        #expect(note.speaker("a")?.colourIndex == 1)
    }

    @Test func overlapWordTimesDetermineSlotsAndStableTiesWithoutSortingWords() {
        let segments: [TranscriptSegment] = [
            .init(text: "A", start: 0, end: 20, speakerID: "a",
                  words: [.init(text: "later", start: 10, end: 11), .init(text: "earlier", start: 4, end: 5)]),
            .init(text: "B", start: 2, end: 3, speakerID: "b", words: [.init(text: "first", start: 2, end: 3)]),
            .init(text: "C", start: 2, end: 3, speakerID: "c")]
        #expect(SpeakerColourOrder.segments(segments) == ["b", "c", "a"])
        var note = Note(title: "Bootstrap")
        let bootstrap = NoteSpeaker.oneVoice(prefix: "run_", language: "en")
        note.transcript = Note.oneVoice(segments, bootstrap)
        note.speakers = [bootstrap]
        note.applySpeakerAnalysis(turns: [.init(speakerID: "a", start: 4, end: 11),
                                          .init(speakerID: "b", start: 2, end: 3)],
                                  matches: [:], voiceNames: [:], autoName: false,
                                  stamp: .init(date: Date(timeIntervalSince1970: 1)), attributed: Array(segments.prefix(2)))
        #expect(note.speaker("b")?.colourIndex == 0)
        #expect(note.speaker("a")?.colourIndex == 1)
        #expect(note.transcript.map(\.id) == Array(segments.prefix(2)).map(\.id))
        #expect(note.transcript.map(\.words) == Array(segments.prefix(2)).map(\.words))
    }

    @Test func portableFallbackUsesTimedSpeechWhileKeepingCanonicalWords() throws {
        let words = [Word("a", 600, 900, "Later"), Word("b", 0, 500, "First")]
        let bytes = try PortableFixtures.document(words, title: "Unsorted", labels: ["a": "Alex", "b": "Ben"])
        let imported = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        #expect(imported.speakers.map(\.id) == ["a", "b"])
        #expect(imported.speakers.map(\.colourIndex) == [1, 0])
        #expect(imported.segments.map(\.text) == ["Later", "First"])
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
        #expect(imported.speakers.map(\.provenance) == [.unnamed, .source])
    }

}
