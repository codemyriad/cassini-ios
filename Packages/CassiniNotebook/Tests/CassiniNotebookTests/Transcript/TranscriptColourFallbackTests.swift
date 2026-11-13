import Testing
@testable import CassiniNotebook

@Suite struct TranscriptColourFallbackTests {
    private var words: [DraftWord] {
        [.init(speaker: "a", startMs: 10_000, endMs: 11_000, text: "Later"),
         .init(speaker: "b", startMs: 0, endMs: 1_000, text: "First"),
         .init(speaker: "c", startMs: 5_000, endMs: 6_000, text: "Middle")]
    }

    @Test(arguments: [false, true])
    func completeRawDraftReservationsNeverRunTheFallback(merged: Bool) throws {
        let hints = ["a": 8, "b": 3, "c": 12]
        var names = DraftNames(labels: ["a": "Alex", "b": "Blair"], colourIndices: hints)
        if merged { names = try names.merge("c", into: "b") }
        let raw = DraftState(words: words, tentativeFromMs: .max)
        var calls = 0
        let shown = DraftView.build(raw, names: names, voiceNames: [:], reserveColours: { names, words in
            calls += 1
            return names.observingWords(words)
        })
        #expect(calls == 0)
        #expect(shown.colourIndices == hints)
        #expect(shown.words.map(\.speaker) == (merged ? ["a", "b", "b"] : ["a", "b", "c"]))
    }

    @Test func producerHintsAreUsedAndPartialReservationsKeepTheirSlots() {
        let raw = DraftState(words: words, tentativeFromMs: .max, colourIndices: ["a": 8, "b": 3, "c": 12])
        var calls = 0
        let complete = DraftView.build(raw, names: .empty, voiceNames: [:], reserveColours: { names, words in
            calls += 1; return names.observingWords(words)
        })
        #expect(calls == 0 && complete.colourIndices == raw.colourIndices)
        let partial = DraftView.build(.init(words: words, tentativeFromMs: .max),
            names: .init(colourIndices: ["a": 8]), voiceNames: [:], reserveColours: { names, words in
                calls += 1; return names.observingWords(words)
            })
        #expect(calls == 1)
        #expect(partial.colourIndices == ["a": 8, "b": 9, "c": 10], "earliest missing speech appends after the known slot")
    }

    @Test func completeSealedSlotsSkipEarliestSpeechEvenForUnnamedSpeakers() {
        let note = TranscriptFixtures.note([.init("a", 10_000, 11_000, "Later"), .init("b", 0, 1_000, "First")],
            speakers: [.init(id: "a", name: "Speaker 2", colourIndex: 8, provenance: .user),
                       .init(id: "b", name: "Speaker 1", colourIndex: 3, provenance: .unnamed)])
        var calls = 0
        let shown = NoteTranscripts.sealed(note, colourOrder: { words in calls += 1; return SpeakerColourOrder.words(words) })
        #expect(calls == 0)
        #expect(shown.speakerTints == ["a": .named(8), "b": .stone])
        #expect(shown == NoteTranscripts.sealed(note))
    }

    @Test func aPartialSealedRosterRunsTheEarliestFallbackOnceAndKeepsKnownSlots() {
        let note = TranscriptFixtures.note([.init("a", 10_000, 11_000, "Later"), .init("b", 0, 1_000, "First")],
            speakers: [.init(id: "a", name: "Alex", colourIndex: 8), .init(id: "b", name: "Blair")])
        var calls = 0
        let shown = NoteTranscripts.sealed(note, colourOrder: { words in calls += 1; return SpeakerColourOrder.words(words) })
        #expect(calls == 1)
        #expect(shown.speakerTints == ["a": .named(8), "b": .named(9)])
    }

    @Test func completeDraftSlotsSkipEarliestSpeechAndPreserveStoneProvenance() {
        var calls = 0
        let shown = NoteTranscripts.draft(words, tentativeFromMs: nil, labels: ["a": "Speaker 2", "c": "Casey"],
            colourIndices: ["a": 8, "b": 3, "c": 12], provenance: ["a": .user, "b": .unnamed, "c": .user],
            colourOrder: { words in calls += 1; return SpeakerColourOrder.words(words) })
        #expect(calls == 0)
        #expect(shown.speakerTints == ["a": .named(8), "b": .stone, "c": .named(12)])
    }

    @Test(arguments: [false, true])
    func legacyAndPartialDraftFallbacksUseTimedSpeechAndNeverReuseKnownSlots(partial: Bool) {
        var calls = 0
        let shown = NoteTranscripts.draft(words, tentativeFromMs: nil, labels: ["a": "Alex", "b": "Blair", "c": "Casey"],
            colourIndices: partial ? ["a": 8, "historical": 40] : [:],
            colourOrder: { words in calls += 1; return SpeakerColourOrder.words(words) })
        #expect(calls == 1)
        #expect(shown.speakerTints == (partial ? ["a": .named(8), "b": .named(41), "c": .named(42)]
                                                  : ["a": .named(2), "b": .named(0), "c": .named(1)]))
    }
}
