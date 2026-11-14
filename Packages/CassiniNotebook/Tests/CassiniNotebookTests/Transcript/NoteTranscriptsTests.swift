import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Paragraphs, tints, badges, suggestion cards, the active word and in-note search.
@Suite struct NoteTranscriptsTests {
    typealias F = TranscriptFixtures

    @Test func anIntentionallyUnnamedSuggestedFixtureShowsTheCardButALiteralUserNameDoesNot() throws {
        let sam = F.voice("Sam Rivera")
        for provenance in [NoteSpeaker.Provenance.unnamed, .user] {
            var note = Note(title: "Speaker fixture")
            note.transcript = [.init(text: "Hello", start: 0, end: 6, speakerID: "alex"),
                               .init(text: "Welcome", start: 6, end: 14, speakerID: "sam"),
                               .init(text: "Thanks", start: 14, end: 24, speakerID: "alex")]
            note.speakers = [.init(id: "alex", name: "Alex", colourIndex: 0),
                             .init(id: "sam", name: "Sam", colourIndex: 1)]
            // Like the UI fixture, start with named Sam. Changing only text deliberately keeps .user.
            note.speakers?[1].name = DefaultLabels.placeholder(2, language: "en")
            #expect(note.speakers?[1].provenance == .user)
            note.speakers?[1].provenance = provenance
            note.speakers?[1].match = .suggested(voice: sam.id, score: 0.78)
            note.refreshSpeakerLabels()
            let reloaded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
            let transcript = NoteTranscripts.sealed(reloaded, voices: [sam],
                suggestions: SpeakerSuggestions.of(reloaded, voices: [sam]))
            let cards = transcript.turns.flatMap(\.allSuggestions)
            let shownNames = transcript.turns.flatMap { [$0.name] + $0.interjections.map(\.name) }
            if provenance == .unnamed {
                #expect(cards.count == 1)
                #expect(cards.first?.speakerID == "sam" && cards.first?.voiceName == "Sam Rivera")
                #expect(transcript.speakerTints["sam"] == .stone)
                #expect(shownNames.contains(.placeholder(2, label: "Speaker 2")))
            } else {
                #expect(cards.isEmpty)
                #expect(transcript.speakerTints["sam"] == .magenta)
                #expect(shownNames.contains(.named("Speaker 2")))
            }
        }
    }

    // ports: NoteTranscriptsTest#sealedTurnsFollowTheSpeakersWithTintsAndPlaceholders
    @Test func sealedTurnsFollowTheSpeakersWithTintsAndPlaceholders() {
        let transcript = NoteTranscripts.sealed(F.weeklySync)
        let turns = transcript.turns
        #expect(turns.map(\.id) == ["w0", "w2", "w3", "w4"])
        #expect(turns.map(\.speakerID) == ["a", "b", "c", "a"])
        #expect(turns[0].name == .named("Giulia"))
        #expect(turns[1].name == .placeholder(2, label: "Speaker 2"))
        // Unnamed speakers hide their colour but reserve their first-speech slot.
        #expect(turns.map(\.tint) == [.blue, .stone, .cyan, .blue])
        #expect(turns[0].text == "Hello everyone.")
        #expect(turns[0].words[1].start == 0.5)
        #expect(transcript.speakers == ["a", "b", "c"])
    }

    // ports: NoteTranscriptsTest#autoBadgeAndSuggestionComeFromTheMatches
    @Test func autoBadgeAndSuggestionComeFromTheMatches() {
        let paolo = F.voice("Paolo Ferri"), luca = F.voice("Luca")
        var note = F.weeklySync
        note.speakers?[2].match = .auto(voice: paolo.id, score: 0.8)
        note.speakers?[1].match = .suggested(voice: luca.id, score: 0.6)
        let voices = [paolo, luca]
        let turns = NoteTranscripts.sealed(note, voices: voices, suggestions: SpeakerSuggestions.of(note, voices: voices)).turns
        #expect(turns[2].auto, "Paolo's label equals his automatic voice")
        #expect(!turns[0].auto)
        #expect(turns[1].suggestion?.voiceID == luca.id)
        #expect(turns[1].suggestion?.voiceName == "Luca")
        #expect(turns.filter { $0.speakerID != "b" }.allSatisfy { $0.suggestion == nil })
    }

    // ports: NoteTranscriptsTest#aSuggestionToAForgottenVoiceIsNotShown
    @Test func aSuggestionToAForgottenVoiceIsNotShown() {
        var note = F.weeklySync
        note.speakers?[1].match = .suggested(voice: UUID(), score: 0.6)
        let turns = NoteTranscripts.sealed(note, voices: [], suggestions: SpeakerSuggestions.of(note, voices: [])).turns
        #expect(turns[1].suggestion == nil)
    }

    /// iOS: a renamed automatic match is no longer "auto"; a passage without a speaker is nobody's, in amber.
    @Test func aRenamedMatchLosesTheBadgeAndAPassageWithoutASpeakerIsUnknown() {
        let paolo = F.voice("Paolo Ferri")
        var note = F.weeklySync
        note.speakers?[2].match = .auto(voice: paolo.id, score: 0.8)
        note.speakers?[2].name = "Paolo"
        note.transcript[1].speakerID = nil
        let turns = NoteTranscripts.sealed(note, voices: [paolo]).turns
        #expect(!turns[2].auto)
        #expect(turns[1].name == .unknown)
        #expect(turns[1].tint == .stone)
    }

    // ports: NoteTranscriptsTest#theActiveWordIsTheLastWordThatStarted
    @Test func theActiveWordIsTheLastWordThatStarted() {
        let transcript = NoteTranscripts.sealed(F.weeklySync)
        #expect(transcript.activeWord(at: 0) == WordRef(turnID: "w0", index: 0))
        #expect(transcript.activeWord(at: F.s(450)) == WordRef(turnID: "w0", index: 0))
        #expect(transcript.activeWord(at: F.s(500)) == WordRef(turnID: "w0", index: 1))
        #expect(transcript.activeWord(at: F.s(2_900)) == WordRef(turnID: "w3", index: 0))
        #expect(transcript.activeWord(at: F.s(3_500)) == WordRef(turnID: "w4", index: 1), "the word that starts at the position plays")
        #expect(transcript.activeWord(at: 99) == WordRef(turnID: "w4", index: 1))
        let late = NoteTranscripts.sealed(F.note([.init("a", 100, 200, "x")]))
        #expect(late.activeWord(at: 0.05) == nil)
        #expect(transcript.turnStart("w4") == 3)
        #expect(transcript.wordStart(WordRef(turnID: "w4", index: 1)) == 3.5)
    }

    /// D47: a placeholder shows as it was written, in its own language, and a speaker without a label gets one in the
    /// app's language. Android still shows its placeholders in the reader's language.
    @Test func aPlaceholderShowsAsStored() {
        #expect(NoteTranscripts.name(label: "Voce 2", id: "b", ordinal: 0) == .placeholder(2, label: "Voce 2"))
        #expect(NoteTranscripts.name(label: "Intervenant 3", id: "c", ordinal: 1) == .placeholder(3, label: "Intervenant 3"))
        #expect(NoteTranscripts.name(label: "b", id: "b", ordinal: 1) == .placeholder(2, label: DefaultLabels.placeholder(2)))
        #expect(NoteTranscripts.name(label: nil, id: "b", ordinal: 3) == .placeholder(4, label: DefaultLabels.placeholder(4)))
        #expect(NoteTranscripts.name(label: "Giulia", id: "a", ordinal: 0) == .named("Giulia"))
    }

    // ports: NoteTranscriptsTest#oneLongSpeakerIsSplitIntoParagraphs
    @Test func oneLongSpeakerIsSplitIntoParagraphs() {
        let long = (0..<450).map { i in F.W("a", i * 100, i * 100 + 90, i == 129 ? "end." : "w\(i)") }
        let turns = NoteTranscripts.sealed(F.note(long)).turns
        #expect(turns.map(\.words.count) == [130, 140, 140, 40], "viewer readable blocks use a 96-word sentence target and 140-word limit")
        #expect(turns.map(\.id) == ["w0", "w130", "w270", "w410"])
        #expect(turns.allSatisfy { $0.speakerID == "a" })
    }

    // ports: NoteTranscriptsTest#theDraftNumbersPlaceholdersByFirstWordAndMarksUnsettledWords
    /// iOS drafts have no names, automatic names or suggestions: speakers are told apart after the words.
    @Test func theDraftNumbersPlaceholdersByFirstWordAndMarksUnsettledWords() {
        let words = F.words.map { DraftWord(speaker: $0.speaker!, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text) }
        let draft = NoteTranscripts.draft(words, tentativeFromMs: 3_600)
        let turns = draft.turns
        #expect(turns.map(\.name) == [1, 2, 3, 1].map { .placeholder($0, label: "Speaker \($0)") })
        #expect(turns.allSatisfy { $0.tint == .stone && !$0.auto && $0.suggestion == nil })
        #expect(turns[3].unsettledFrom == 1, "so ends after 3.6 s")
        #expect(turns[0].unsettledFrom == nil)
        #expect(draft.activeWord(at: 3.1) == WordRef(turnID: "w4", index: 0))
        #expect(NoteTranscripts.draft(words, tentativeFromMs: nil).turns.allSatisfy { $0.unsettledFrom == nil },
                "a stopped draft has no unsettled words")
    }

    // ports: NoteTranscriptsTest#searchIgnoresCaseAndAccents
    @Test func searchIgnoresCaseAndAccents() {
        let turns = NoteTranscripts.sealed(F.note([.init("a", 0, 1, "Café"), .init("a", 1, 2, "DELIVERY"),
                                                   .init("b", 2, 3, "cafe delivery")])).turns
        let cafe = TranscriptSearch.matches(turns, query: "cafe")
        #expect(cafe.count == 2)
        #expect(cafe[0].turnID == "w0")
        #expect(cafe[0].range == 0..<4)
        #expect(cafe[1].range == 0..<4)
        #expect(TranscriptSearch.matches(turns, query: "Delivery").map(\.range) == [5..<13, 5..<13])
        #expect(TranscriptSearch.matches(turns, query: "  ").isEmpty)
        #expect(TranscriptSearch.matches(turns, query: "tomorrow").isEmpty)
    }

    // ports: NoteTranscriptsTest#aDecomposedAccentKeepsTheRangeOnTheSourceText
    /// Swift ranges count characters, so the decomposed "é" is one character and the match covers it whole.
    @Test func aDecomposedAccentKeepsTheRangeOnTheSourceText() {
        let turns = NoteTranscripts.sealed(F.note([.init("a", 0, 1, "Cafe\u{301} aperto")])).turns
        let match = TranscriptSearch.matches(turns, query: "café")
        #expect(match.map(\.range) == [0..<4], "the combining mark belongs to the match")
        #expect(String(Array(turns[0].text)[match[0].range]) == "Cafe\u{301}")
    }

    @Test func searchStepsWrapAroundAndANewQueryStartsAgain() {
        var search = InNoteSearch(query: " cafe ")
        #expect(search.query == "cafe")
        search.next(of: 2)
        #expect(search.current == 1)
        search.next(of: 2)
        #expect(search.current == 0, "it wraps around")
        search.previous(of: 2)
        #expect(search.current == 1)
        search.setQuery("tomorrow")
        #expect(search.current == 0)
        #expect(search.current(of: 0) == 0)
    }

    @Test func aWordIsFoundByItsCharacterOffset() {
        let turn = NoteTranscripts.sealed(F.weeklySync).turns[0]
        #expect(turn.offsets == [0, 6])
        #expect(turn.range(ofWord: 1) == 6..<15)
        #expect(turn.word(atOffset: 4) == 0)
        #expect(turn.word(atOffset: 7) == 1)
    }
}

extension NoteTranscriptsTests {
    @Test func sealedChipOnlySuggestionKeepsItsSpeakerTintAndNamingTargets() throws {
        let vector = try D84IntegrationVector.load("acknowledgment")
        let voice = F.voice("Ben Carter")
        var note = Note(title: "Release check-in")
        note.transcript = TranscriptSegment.segments(of: vector.words)
        note.speakers = [.init(id: "ada", name: "Ada"),
                         .init(id: "ben", name: "Speaker 2", match: .suggested(voice: voice.id, score: 0.7))]
        let cards = SpeakerSuggestions.of(note, voices: [voice])
        let transcript = NoteTranscripts.sealed(note, voices: [voice], suggestions: cards)
        let row = try #require(transcript.turns.first)
        #expect(transcript.turns.count == 1 && row.speakerID == "ada")
        #expect(transcript.speakers == ["ada", "ben"])
        #expect(row.suggestion == nil)
        #expect(row.inlineSuggestions == cards)
        #expect(row.allSuggestions.map(\.speakerID) == ["ben"])
        #expect(row.allSuggestions.first?.start == 3.05)
        #expect(row.interjections.first?.name == .placeholder(2, label: "Speaker 2"))
        #expect(row.interjections.first?.tint == .stone)
        #expect(transcript.speakerTints["ben"] == .stone)
        let ben = try #require(NamingInput.of(note, speakerID: "ben", print: nil, voices: [voice],
                                              voicesReadOnly: false, voiceModelReady: false))
        let ada = try #require(NamingInput.of(note, speakerID: "ada", print: nil, voices: [voice],
                                              voicesReadOnly: false, voiceModelReady: false))
        #expect(ben.mergeTargets.map(\.speakerID) == ["ada"])
        #expect(ada.mergeTargets.map(\.speakerID) == ["ben"])
        #expect(ben.ordinal == 1 && ben.label == "Speaker 2")
        note.speakers?[1].name = "Ben"
        let named = NoteTranscripts.sealed(note, voices: [voice], suggestions: SpeakerSuggestions.of(note, voices: [voice]))
        #expect(named.turns[0].allSuggestions.isEmpty)
        #expect(named.speakers == ["ada", "ben"])
        #expect(named.turns[0].interjections.first?.tint == .magenta)
        #expect(named.speakerTints["ben"] == .magenta)
    }

    @Test func aRepeatedChipSpeakerGetsOneSealedCardAndItsLatestDraftCard() throws {
        let vector = try D84IntegrationVector.load("acknowledgment")
        let later = vector.words.map { CassiniCore.Word($0.speaker, $0.startMs + 20_000, $0.endMs + 20_000, $0.text) }
        let words = vector.words + later
        let voice = F.voice("Ben Carter")
        var note = Note(title: "Two updates")
        note.transcript = TranscriptSegment.segments(of: words)
        note.speakers = [.init(id: "ada", name: "Ada"),
                         .init(id: "ben", name: "Speaker 2", match: .suggested(voice: voice.id, score: 0.7))]
        let sealed = NoteTranscripts.sealed(note, voices: [voice], suggestions: SpeakerSuggestions.of(note, voices: [voice]))
        #expect(sealed.turns.flatMap(\.interjections).count == 2)
        #expect(sealed.turns.flatMap(\.allSuggestions).map(\.speakerID) == ["ben"])
        #expect(sealed.turns.flatMap(\.allSuggestions).first?.start == 3.05)
        let raw = words.map { DraftWord(speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }
        let card = DraftSuggestion(speakerID: "ben", voiceID: voice.id, name: voice.name, score: 0.7, atMs: 23_050)
        let draft = NoteTranscripts.draft(raw, tentativeFromMs: 23_000, labels: ["ada": "Ada"], suggestions: [card, card])
        let placed = draft.turns.filter { !$0.allSuggestions.isEmpty }
        #expect(placed.count == 1)
        #expect(placed.first?.inlineSuggestions.map(\.speakerID) == ["ben"])
        #expect(placed.first?.allSuggestions.first?.start == 23.05)
        #expect(placed.first?.start == 20)
        #expect(placed.first?.unsettledWordIndices.isEmpty == false, "Placing tentative words retains its cards")
    }

    @Test func draftCardsUseActualSpeakerWordsInsideARejoinedRow() throws {
        let vector = try D84IntegrationVector.load("acknowledgment")
        let raw = vector.words.map { DraftWord(speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, text: $0.text) }
        let ada = UUID(), ben = UUID()
        let cards = [DraftSuggestion(speakerID: "ada", voiceID: ada, name: "Ada", score: 0.7, atMs: 3500),
                     DraftSuggestion(speakerID: "ben", voiceID: ben, name: "Ben", score: 0.7, atMs: 3050)]
        let draft = NoteTranscripts.draft(raw, tentativeFromMs: nil, suggestions: cards)
        let row = try #require(draft.turns.first)
        #expect(draft.turns.count == 1)
        #expect(row.start == 0)
        #expect(row.suggestion?.speakerID == "ada" && row.suggestion?.start == 3.5)
        #expect(row.inlineSuggestions.map(\.speakerID) == ["ben"])
        #expect(row.allSuggestions.map(\.speakerID) == ["ada", "ben"])
        #expect(row.allSuggestions.map(\.start) == [3.5, 3.05])
    }

    // ports: NoteTranscriptsTest#namingQuotesUseOnlyTheSelectedSpeakersFirstSpeechInBothTranscriptForms
    @Test func namingQuotesUseOnlyTheSelectedSpeakersFirstSpeechInBothTranscriptForms() throws {
        let sealed = NoteTranscripts.sealed(F.weeklySync)
        #expect(sealed.namingQuote("a") == "Hello everyone.")
        #expect(sealed.namingQuote("b") == "Welcome")
        #expect(sealed.namingQuote("c") == "Here")
        #expect(sealed.namingQuote("missing") == "")

        let giulia = try #require(NamingInput.of(F.weeklySync, speakerID: "a", print: nil, voices: [],
                                                 voicesReadOnly: false, voiceModelReady: false))
        #expect(giulia.quote == "Hello everyone.")

        let draftWords = F.words.map { DraftWord(speaker: $0.speaker!, startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text) }
        let draft = NoteTranscripts.draft(draftWords, tentativeFromMs: 3_600)
        #expect(draft.namingQuote("a") == "Hello everyone.")
        #expect(draft.namingQuote("b") == "Welcome")
        #expect(draft.namingQuote("c") == "Here")

        // Inline overlap-chip speaker: quote extracts only ben's spoken words, never synthetic "(Name: …)" labels.
        let vector = try D84IntegrationVector.load("acknowledgment")
        var overlapNote = Note(title: "Overlap")
        overlapNote.transcript = TranscriptSegment.segments(of: vector.words)
        overlapNote.speakers = [.init(id: "ada", name: "Ada"), .init(id: "ben", name: "Speaker 2")]
        let overlap = NoteTranscripts.sealed(overlapNote)
        #expect(overlap.namingQuote("ben") == "Sounds good.")
        #expect(!overlap.namingQuote("ada").contains("Sounds good"))

        // Byte-distinct canonical-equivalent speaker IDs ("e\u{0301}" vs "\u{00E9}") never cross-contaminate quotes.
        let decomposed = "e\u{0301}", precomposed = "\u{00E9}"
        var canonical = Note(title: "Canonical IDs")
        canonical.speakers = [.init(id: decomposed, name: "One"), .init(id: precomposed, name: "Two")]
        canonical.transcript = [.init(text: "First speaker.", start: 0, end: 1, speakerID: decomposed),
                                .init(text: "Second speaker.", start: 2, end: 3, speakerID: precomposed)]
        let canonicalTranscript = NoteTranscripts.sealed(canonical)
        #expect(canonicalTranscript.namingQuote(decomposed) == "First speaker.")
        #expect(canonicalTranscript.namingQuote(precomposed) == "Second speaker.")
    }

    // ports: NoteTranscriptsTest#namingQuotesBoundLongSpeechAndNeverSplitASurrogatePair
    @Test func namingQuotesBoundLongSpeechAndNeverSplitASurrogatePair() {
        let fortyOne = (1...41).map { i in F.W("a", i * 100, i * 100 + 80, "w\(i)") }
        let expectedForty = (1...40).map { "w\($0)" }.joined(separator: " ") + "…"
        #expect(NoteTranscripts.sealed(F.note(fortyOne)).namingQuote("a") == expectedForty)

        let surrogateToken = String(repeating: "x", count: 239) + "😀more"
        let surrogateQuote = NoteTranscripts.sealed(F.note([F.W("a", 0, 100, surrogateToken)])).namingQuote("a")
        #expect(surrogateQuote == String(repeating: "x", count: 239) + "…")
        #expect(!surrogateQuote.utf16.contains { (0xD800...0xDFFF).contains($0) })

        // Multi-scalar grapheme cluster ("👍🏽" = 4 UTF-16 units) at the 240-UTF-16 limit is dropped whole, never split.
        let modifierToken = String(repeating: "x", count: 238) + "👍🏽more"
        let modifierQuote = NoteTranscripts.sealed(F.note([F.W("a", 0, 100, modifierToken)])).namingQuote("a")
        #expect(modifierQuote == String(repeating: "x", count: 238) + "…")

        #expect(NoteTranscripts.sealed(Note(title: "Empty")).namingQuote("a") == "")
    }

    @Test func namingQuoteStopsAtFirstContiguousRunOnLargeTranscript() {
        let words: [F.W] = (0..<6_000).map { index in
            let speaker = index < 4 ? "a" : (index < 5_996 ? "b" : "a")
            return F.W(speaker, index * 200, index * 200 + 150, "w\(index)")
        }
        let transcript = NoteTranscripts.sealed(F.note(words))
        let expectedB = (4..<44).map { "w\($0)" }.joined(separator: " ") + "…"
        #expect(transcript.namingQuote("a") == "w0 w1 w2 w3")
        #expect(transcript.namingQuote("b") == expectedB)
    }
}
