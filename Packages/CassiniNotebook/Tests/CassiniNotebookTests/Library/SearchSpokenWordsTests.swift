import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct SearchSpokenWordsTests {
    private struct Fixture: Decodable {
        struct Item: Decodable { let speaker: String; let startMs: Int64; let endMs: Int64; let text: String }
        let items: [Item]
    }

    private func inlineReply() throws -> Note {
        let url = try #require(Bundle.module.url(forResource: "acknowledgment.words", withExtension: "json", subdirectory: "interjections"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var note = Note(title: "Release planning", createdAt: Date(timeIntervalSince1970: 1))
        note.status = .ready
        note.speakers = [NoteSpeaker(id: "ada", name: "Ada"), NoteSpeaker(id: "ben", name: "Ben")]
        note.transcript = fixture.items.map {
            TranscriptSegment(text: $0.text, start: Double($0.startMs) / 1_000, end: Double($0.endMs) / 1_000,
                              speaker: $0.speaker == "ben" ? "Ben" : "Ada", speakerID: $0.speaker)
        }
        return note
    }

    @Test func searchIndexesSpeechAndFindMapsAnInlineReplyBackToItsWord() throws {
        let note = try inlineReply()
        let transcript = NoteTranscripts.sealed(note)
        let host = try #require(transcript.turns.first { !$0.interjections.isEmpty })
        #expect(host.text.contains("Ben:"), "the presentation includes the synthetic label")
        var index = LibraryIndex([note])
        #expect(index.search(SearchQuery("Ben")).isEmpty, "a synthetic speaker label is not speech")
        #expect(TranscriptSearch.matches(transcript.turns, query: "Ben").isEmpty)
        #expect(index.search(SearchQuery("Sounds good")).map(\.entry.note.id) == [note.id])
        let hit = try #require(TranscriptSearch.matches(transcript.turns, query: "sounds good").first)
        let turn = try #require(transcript.turns.first { $0.id == hit.turnID })
        #expect(String(Array(turn.text)[hit.range]) == "Sounds good")
        let word = try #require(turn.word(atOffset: hit.range.lowerBound))
        #expect(turn.words[word].speakerID == "ben")
        #expect(turn.words[word].text == "Sounds")
    }

    @Test func aSpokenNameStillMatchesAfterTheSpeakerIsRenamed() throws {
        var note = try inlineReply()
        note.transcript.append(TranscriptSegment(text: "Ask Ben tomorrow.", start: 60, end: 62, speaker: "Ada", speakerID: "ada"))
        var index = LibraryIndex([note])
        #expect(index.search(SearchQuery("Ben")).count == 1)
        #expect(TranscriptSearch.matches(NoteTranscripts.sealed(note).turns, query: "Ben").count == 1)
        note.speakers?[1].name = "Benjamin"
        index.update([note])
        #expect(index.search(SearchQuery("Ben")).count == 1)
        #expect(index.search(SearchQuery("Benjamin")).isEmpty)
        let transcript = NoteTranscripts.sealed(note)
        #expect(TranscriptSearch.matches(transcript.turns, query: "Benjamin").isEmpty)
        let hits = TranscriptSearch.matches(transcript.turns, query: "Ben")
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        let turn = try #require(transcript.turns.first { $0.id == hit.turnID })
        #expect(String(Array(turn.text)[hit.range]) == "Ben")
    }

    @Test func aSearchExcerptCrossingParagraphsKeepsTheMatchedWordOnThePreviewLine() throws {
        var note = Note(title: "Focused work", createdAt: Date(timeIntervalSince1970: 1))
        note.status = .ready
        note.transcript = [
            TranscriptSegment(text: "The best ideas usually arrive in the space between things. A walk, a conversation, a moment to pause.",
                              start: 0, end: 14, speaker: "Sam", speakerID: "sam"),
            TranscriptSegment(text: "Let’s protect an hour on Thursday for focused work. No notifications, no meetings. Just room to think.",
                              start: 14, end: 24, speaker: "Alex", speakerID: "alex")
        ]
        var index = LibraryIndex([note])
        let hit = try #require(index.search(SearchQuery("Thursday")).first)
        let snippet = try #require(hit.markedSnippet)
        let hasNewline = snippet.text.contains { $0.isNewline }
        #expect(!hasNewline, "paragraph breaks must not consume the two-line snippet")
        #expect(snippet.ranges.map { String(Array(snippet.text)[$0]) } == ["Thursday"])
    }
    @Test func aPhraseAcrossAnInlineLabelKeepsItsDisplayedWordOffsets() throws {
        let transcript = NoteTranscripts.sealed(try inlineReply())
        let hit = try #require(TranscriptSearch.matches(transcript.turns, query: "testing, Sounds").first)
        let turn = try #require(transcript.turns.first { $0.id == hit.turnID })
        #expect(String(Array(turn.text)[hit.range]) == "testing, (Ben: Sounds")
        let first = try #require(turn.word(atOffset: hit.range.lowerBound))
        let last = try #require(turn.word(atOffset: hit.range.upperBound - 1))
        #expect(turn.words[first].text == "testing,")
        #expect(turn.words[last].text == "Sounds")
        #expect(turn.words[last].speakerID == "ben")
    }

    @Test(arguments: [false, true])
    func standalonePunctuationKeepsViewerSpacingInFindAndLibrary(inline: Bool) throws {
        var note = try inlineReply()
        if !inline { note.transcript = [TranscriptSegment(text: "Hello world. Hello to everyone", start: 0, end: 3, speakerID: "ada")] }
        note.transcript = note.transcript.map { segment in
            var segment = segment
            // Apple Speech emits punctuation separately, including zero-duration punctuation.
            let atoms = segment.text == "good." ? ["world", ".", "Hello"]
                : segment.text.split(separator: " ").flatMap { token -> [String] in
                    if let last = token.last, ",.!?:;)".contains(last) {
                        return [String(token.dropLast()), String(last)]
                    }
                    return [String(token)]
                }
            let step = (segment.end - segment.start) / Double(atoms.count)
            segment.words = atoms.enumerated().map { index, text in
                let start = segment.start + Double(index) * step
                return TimedWord(text: text, start: start, end: text == "." ? start : start + step)
            }
            return segment
        }
        let turns = NoteTranscripts.sealed(note).turns
        #expect(turns.contains { !$0.interjections.isEmpty } == inline)
        for query in ["world.", "world. Hello"] {
            let hit = try #require(TranscriptSearch.matches(turns, query: query).first)
            let turn = try #require(turns.first { $0.id == hit.turnID })
            #expect(String(Array(turn.text)[hit.range]) == query)
            let word = try #require(turn.word(atOffset: hit.range.lowerBound))
            #expect(turn.words[word].speakerID == (inline ? "ben" : "ada"))
        }
        #expect(TranscriptSearch.matches(turns, query: "world .").isEmpty)
        let fields = SearchFields(note)
        let snippet = Highlighted(marked: fields.snippet(try #require(SearchQuery("world"))))
        #expect(snippet.text.contains("world. Hello"))
        #expect(!snippet.text.contains("world ."))
        #expect(!snippet.text.contains("testing ,"))
        #expect(!snippet.text.contains("Ben:"))
        #expect(snippet.ranges.map { String(Array(snippet.text)[$0]) } == ["world"])
    }

    @Test func leadingEmptyDraftAtomsKeepSearchRangesNonnegative() throws {
        let turns = NoteTranscripts.draft([
            DraftWord(speaker: "a", startMs: 0, endMs: 0, text: ""),
            DraftWord(speaker: "a", startMs: 0, endMs: 500, text: "Hello")
        ], tentativeFromMs: nil).turns
        #expect(turns.first?.offsets == [0, 0])
        #expect(TranscriptSearch.matches(turns, query: "Hello").map(\.range) == [0..<5])
    }

    @Test func searchingAnElevenHourTranscriptScalesWithItsWords() throws {
        func transcript(_ count: Int) -> [NoteTurn] {
            NoteTranscripts.draft((0..<count).map { index in
                DraftWord(speaker: "a", startMs: Int64(index) * 400, endMs: Int64(index) * 400 + 300,
                          text: "release")
            }, tentativeFromMs: nil, labels: ["a": "Ada"]).turns
        }
        let small = transcript(50_000), large = transcript(100_000)
        func search(_ turns: [NoteTurn]) {
            precondition(TranscriptSearch.matches(turns, query: "missing").isEmpty)
        }
        search(small); search(large)
        var least = (small: Duration.seconds(1_000), large: Duration.seconds(1_000))
        for _ in 0..<3 {
            least.small = min(least.small, try measureThreadCPU { search(small) }.elapsed)
            least.large = min(least.large, try measureThreadCPU { search(large) }.elapsed)
        }
        let ratio = least.large / least.small
        #expect(ratio < 3.5, "2x the words must stay below quadratic growth in calling-thread CPU: \(ratio)")
    }

}
