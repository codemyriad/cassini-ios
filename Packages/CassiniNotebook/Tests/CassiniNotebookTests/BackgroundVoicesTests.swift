import Foundation
import Testing
import CassiniCore
@testable import CassiniNotebook

@Suite struct BackgroundVoicesTests {
    private func sampleSevenSpeakerNote() -> Note {
        var note = Note(title: "Incontro ORA")
        note.duration = 60
        note.speakers = [
            NoteSpeaker(id: "s1", name: "Silvio", colourIndex: 0, provenance: .user),
            NoteSpeaker(id: "s2", name: "Ruurd", colourIndex: 1, provenance: .user),
            NoteSpeaker(id: "s3", name: "Speaker 3", colourIndex: 2, provenance: .unnamed),
            NoteSpeaker(id: "s4", name: "Speaker 4", colourIndex: 3, provenance: .unnamed),
            NoteSpeaker(id: "s5", name: "Speaker 5", colourIndex: 4, provenance: .unnamed),
            NoteSpeaker(id: "s6", name: "Speaker 6", colourIndex: 5, provenance: .unnamed),
            NoteSpeaker(id: "s7", name: "Speaker 7", colourIndex: 6, provenance: .unnamed),
        ]
        note.transcript = [
            TranscriptSegment(text: "Let us start the review.", start: 0, end: 4, speaker: "Silvio", speakerID: "s1",
                              words: [TimedWord(text: "Let", start: 0, end: 1), TimedWord(text: "us", start: 1, end: 2), TimedWord(text: "start", start: 2, end: 4)]),
            TranscriptSegment(text: "Agreed on the timeline.", start: 5, end: 9, speaker: "Ruurd", speakerID: "s2",
                              words: [TimedWord(text: "Agreed", start: 5, end: 7), TimedWord(text: "timeline.", start: 7, end: 9)]),
            TranscriptSegment(text: "Espresso please.", start: 10, end: 12, speaker: "Speaker 4", speakerID: "s4",
                              words: [TimedWord(text: "Espresso", start: 10, end: 11), TimedWord(text: "please.", start: 11, end: 12)]),
            TranscriptSegment(text: "By the window.", start: 13, end: 15, speaker: "Speaker 5", speakerID: "s5",
                              words: [TimedWord(text: "By", start: 13, end: 14), TimedWord(text: "window.", start: 14, end: 15)]),
            TranscriptSegment(text: "Thank you.", start: 16, end: 18, speaker: "Speaker 4", speakerID: "s4",
                              words: [TimedWord(text: "Thank", start: 16, end: 17), TimedWord(text: "you.", start: 17, end: 18)]),
            TranscriptSegment(text: "I will book the room.", start: 20, end: 24, speaker: "Speaker 3", speakerID: "s3",
                              words: [TimedWord(text: "I", start: 20, end: 21), TimedWord(text: "book", start: 21, end: 24)]),
            TranscriptSegment(text: "Check please.", start: 25, end: 27, speaker: "Speaker 6", speakerID: "s6",
                              words: [TimedWord(text: "Check", start: 25, end: 26), TimedWord(text: "please.", start: 26, end: 27)]),
            TranscriptSegment(text: "Right away.", start: 28, end: 30, speaker: "Speaker 7", speakerID: "s7",
                              words: [TimedWord(text: "Right", start: 28, end: 29), TimedWord(text: "away.", start: 29, end: 30)]),
        ]
        return note
    }

    private func minimalOpusBytes() throws -> [UInt8] {
        let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let tags = CassiniDocument.tagsPacket([])
        return try OggOpus.mux(OggOpus.Stream(head: head, tags: tags, audio: [[0xF8, 0xFF, 0xFE]], finalGranule: 960, validFraming: true), tags: tags)
    }

    // MARK: - Persistence (D112 / L-86)

    @Test func backgroundEncodesOnlyWhenTrueAndNeverFalse() throws {
        let normal = NoteSpeaker(id: "s1", name: "Sam", provenance: .user, background: false)
        let normalJSON = String(decoding: try JSONEncoder().encode(normal), as: UTF8.self)
        #expect(!normalJSON.contains("\"background\""))
        let decodedNormal = try JSONDecoder().decode(NoteSpeaker.self, from: Data(normalJSON.utf8))
        #expect(!decodedNormal.background)

        let bg = NoteSpeaker(id: "s3", name: "Marta", provenance: .user, background: true)
        let bgJSON = String(decoding: try JSONEncoder().encode(bg), as: UTF8.self)
        #expect(bgJSON.contains("\"background\":true"))
        let decodedBg = try JSONDecoder().decode(NoteSpeaker.self, from: Data(bgJSON.utf8))
        #expect(decodedBg.background)
        #expect(decodedBg.name == "Marta")
        #expect(decodedBg.provenance == .user)
    }

    @Test func backgroundSurvivesOpusExportAndReimportAndSwitchingOffRemovesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-opus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let opus = dir.appendingPathComponent("source.opus")
        try Data(try minimalOpusBytes()).write(to: opus)

        var note = sampleSevenSpeakerNote()
        note.setSpeakerBackground("s4", true)
        note.setSpeakerBackground("s5", true)

        let exported = dir.appendingPathComponent("exported.opus")
        _ = try PortableTranscript.export(note: note, opus: opus, destination: exported, unassignedLabel: "Unknown speaker")

        let readBack = try #require(PortableTranscript.read(from: exported))
        let byID = Dictionary(uniqueKeysWithValues: readBack.speakers.map { ($0.id, $0) })
        #expect(byID["s1"]?.background == false)
        #expect(byID["s4"]?.background == true)
        #expect(byID["s5"]?.background == true)
        #expect(byID["s4"]?.name == "Speaker 4")

        // Switching s4 back off and re-exporting over the verified document removes background from s4.
        note.setSpeakerBackground("s4", false)
        let reexported = dir.appendingPathComponent("reexported.opus")
        _ = try PortableTranscript.export(note: note, opus: exported, destination: reexported, unassignedLabel: "Unknown speaker")
        let readAgain = try #require(PortableTranscript.read(from: reexported))
        let byIDAgain = Dictionary(uniqueKeysWithValues: readAgain.speakers.map { ($0.id, $0) })
        #expect(byIDAgain["s4"]?.background == false)
        #expect(byIDAgain["s5"]?.background == true)
    }

    // MARK: - Header, Folding, Playback, Search, Library, Export

    @Test func backgroundLeavesHeaderLibrarySearchAndExportWhilePlaybackStaysUnchanged() {
        var note = sampleSevenSpeakerNote()
        note.setSpeakerBackground("s4", true)
        note.setSpeakerBackground("s5", true)
        note.setSpeakerBackground("s6", true)
        note.setSpeakerBackground("s7", true)

        let transcript = NoteTranscripts.sealed(note)
        // Header speakers exclude background voices; allHeaderSpeakers keeps every speaker in canonical order.
        #expect(transcript.headerSpeakers.map(\.id) == ["s1", "s2", "s3"])
        #expect(transcript.allHeaderSpeakers.map(\.id) == ["s1", "s2", "s4", "s5", "s3", "s6", "s7"])

        // Consecutive background turns fold into runs counting distinct voices in each run.
        let blocks = TranscriptFolding.items(of: transcript.turns)
        let runs = blocks.compactMap { item -> BackgroundTurnRun? in
            if case .backgroundRun(let run) = item { return run }
            return nil
        }
        #expect(runs.count == 2)
        #expect(runs[0].voiceCount == 2) // s4, s5, s4 -> 2 distinct voices
        #expect(runs[0].turns.count == 3)
        #expect(runs[1].voiceCount == 2) // s6, s7 -> 2 distinct voices
        #expect(runs[1].turns.count == 2)

        // Playback index is unchanged: seeking into a background turn still resolves its active word.
        let bgActive = transcript.activeWord(at: 10.5)
        #expect(bgActive != nil)

        // In-note search excludes background voices.
        #expect(TranscriptSearch.matches(transcript.turns, query: "Espresso").isEmpty)
        #expect(TranscriptSearch.matches(transcript.turns, query: "window").isEmpty)
        #expect(!TranscriptSearch.matches(transcript.turns, query: "timeline").isEmpty)

        // Library index excludes background voices from speaker count, named filter, search, and preview.
        var index = LibraryIndex([note])
        #expect(index.entry(note.id)?.speakerCount == 3)
        #expect(index.search(SearchQuery("Espresso")).isEmpty)
        #expect(index.search(SearchQuery("timeline")).count == 1)

        // Text, Markdown, SRT, VTT exports exclude background voices.
        let export = ExportTranscript(note: note, unassignedLabel: "Unknown speaker")
        let mdCopy = MarkdownCopy(speakersLine: "Speakers: {speakers}", transcriptHeading: "Transcript",
                                  notesHeading: "Notes", overLine: "(over {names})",
                                  speakerList: { $0.joined(separator: ", ") })
        let md = MarkdownExport.write(export, dateLine: "Today · 1 min", copy: mdCopy)
        let txt = TextExport.write(export, subtitle: "Today", emptyText: "No speech")
        let srt = SrtWriter.write(export)
        let vtt = VttWriter.write(export)
        for output in [md, txt, srt, vtt] {
            #expect(!output.contains("Espresso"))
            #expect(!output.contains("window"))
            #expect(output.contains("timeline"))
        }
    }

    @Test func foldingScalesLinearlyOnLongTranscript() throws {
        func makeTurns(_ count: Int) -> [NoteTurn] {
            var note = Note(title: "Long")
            note.duration = Double(count * 2)
            note.speakers = [
                NoteSpeaker(id: "s1", name: "Host", colourIndex: 0, provenance: .user),
                NoteSpeaker(id: "s2", name: "Bg1", colourIndex: 1, provenance: .user, background: true),
                NoteSpeaker(id: "s3", name: "Bg2", colourIndex: 2, provenance: .user, background: true),
            ]
            note.transcript = (0..<count).map { i in
                let spk = i % 3 == 0 ? "s1" : (i % 3 == 1 ? "s2" : "s3")
                return TranscriptSegment(text: "word\(i)", start: Double(i * 2), end: Double(i * 2 + 1),
                                         speaker: spk, speakerID: spk,
                                         words: [TimedWord(text: "word\(i)", start: Double(i * 2), end: Double(i * 2 + 1))])
            }
            return NoteTranscripts.sealed(note).turns
        }
        let n = 1_500
        let turnsN = makeTurns(n)
        let turns2N = makeTurns(n * 2)
        let (_, t1) = try measureThreadCPU { TranscriptFolding.items(of: turnsN) }
        let (_, t2) = try measureThreadCPU { TranscriptFolding.items(of: turns2N) }
        // Linear scaling: 2N should stay well under 6x of N (allowing generous noise floor for fast runs).
        #expect(t2 <= max(t1 * 6, .milliseconds(50)))
    }

    // MARK: - Multi-speaker session & Background switch

    @Test func sevenSpeakerSessionNamesOneAndMarksTwoBackgroundInOneSave() {
        let note = sampleSevenSpeakerNote()
        let roster = SpeakerSheetSession.roster(for: note)
        #expect(roster.count == 7)

        var session = SpeakerSheetSession(roster: roster, selectedSpeakerID: "s3")
        func load(_ id: String) {
            if let input = NamingInput.of(note, speakerID: id, print: nil, voices: [], voicesReadOnly: false, voiceModelReady: true) {
                session.setLoaded(input)
            }
        }
        load("s3")
        // Name Speaker 3 -> "Marta"
        if let s3 = session.currentState {
            session.drafts[Data("s3".utf8)] = SpeakerNaming.reduce(s3, .nameChanged("Marta")).state
        }
        // Switch to s4 without closing, mark background
        session.select("s4")
        load("s4")
        if let s4 = session.currentState {
            let updated = SpeakerNaming.reduce(s4, .backgroundToggled(true)).state!
            session.drafts[Data("s4".utf8)] = updated
            let ui = SpeakerNaming.ui(updated)
            #expect(ui.isBackground)
            #expect(!ui.canMerge)
            #expect(!SpeakerNaming.effectiveRemember(updated))
        }
        // Switch to s5 without closing, mark background
        session.select("s5")
        load("s5")
        if let s5 = session.currentState {
            session.drafts[Data("s5".utf8)] = SpeakerNaming.reduce(s5, .backgroundToggled(true)).state
        }

        // Displayed roster reflects live edits
        let displayed = Dictionary(uniqueKeysWithValues: session.displayedRoster.map { ($0.speakerID, $0) })
        #expect(displayed["s3"]?.label == "Marta")
        #expect(displayed["s4"]?.isBackground == true)
        #expect(displayed["s5"]?.isBackground == true)
        #expect(session.saveState == .enabled)

        // Single Save gathers all three speakers' writes and computes the combined toast summary.
        let (writes, summary) = session.pendingSave()
        #expect(writes.count == 3)
        #expect(summary.namedSpeakers == ["Marta"])
        #expect(summary.markedBackground == ["Speaker 4", "Speaker 5"])
        #expect(summary.toastKind == .namedAndBackground(name: "Marta", count: 2))
    }

    @Test func singleBackgroundVoiceToastAndSwitchingBackPreservesName() {
        var note = sampleSevenSpeakerNote()
        let roster = SpeakerSheetSession.roster(for: note)
        var session = SpeakerSheetSession(roster: roster, selectedSpeakerID: "s1")
        let s1Input = NamingInput.of(note, speakerID: "s1", print: nil, voices: [], voicesReadOnly: false, voiceModelReady: true)!
        session.setLoaded(s1Input)
        session.drafts[Data("s1".utf8)] = SpeakerNaming.reduce(session.currentState!, .backgroundToggled(true)).state

        let (writes, summary) = session.pendingSave()
        #expect(writes.count == 1)
        #expect(writes[0].effects == [.setBackground(speakerID: "s1", background: true)])
        #expect(summary.toastKind == .singleBackground(name: "Silvio"))

        // Applying preserves name "Silvio" and provenance .user; switching back restores it.
        note.setSpeakerBackground("s1", true)
        #expect(note.speaker("s1")?.name == "Silvio")
        #expect(note.speaker("s1")?.background == true)
        note.setSpeakerBackground("s1", false)
        #expect(note.speaker("s1")?.name == "Silvio")
        #expect(note.speaker("s1")?.background == false)
    }

    // MARK: - Mixed-speaker turns (background host + foreground interjection)

    private struct InterjectionFixture: Decodable {
        struct Item: Decodable { let speaker: String; let startMs: Int64; let endMs: Int64; let text: String }
        let items: [Item]
    }

    @Test func backgroundHostPreservesForegroundInterjectionInSearchLibraryAndFolding() throws {
        let url = try #require(Bundle.module.url(forResource: "acknowledgment.words", withExtension: "json", subdirectory: "interjections"))
        let fixture = try JSONDecoder().decode(InterjectionFixture.self, from: Data(contentsOf: url))
        var note = Note(title: "Mixed host", createdAt: Date(timeIntervalSince1970: 1))
        note.status = .ready
        note.speakers = [
            NoteSpeaker(id: "ada", name: "Ada", colourIndex: 0, provenance: .user, background: true),
            NoteSpeaker(id: "ben", name: "Ben", colourIndex: 1, provenance: .user, background: false),
        ]
        note.transcript = fixture.items.map {
            TranscriptSegment(text: $0.text, start: Double($0.startMs) / 1_000, end: Double($0.endMs) / 1_000,
                              speaker: $0.speaker == "ben" ? "Ben" : "Ada", speakerID: $0.speaker)
        }

        let transcript = NoteTranscripts.sealed(note)
        let mixed = try #require(transcript.turns.first { $0.isBackground && !$0.interjections.isEmpty })
        #expect(!mixed.isFullyBackground)
        #expect(mixed.interjections.contains { !$0.isBackground })

        // Folding must NOT hide a mixed turn that contains a foreground interjection.
        let items = TranscriptFolding.items(of: transcript.turns)
        #expect(items.contains { item in
            if case .turn(let turn) = item { return turn.id == mixed.id }
            return false
        })

        // In-note search finds Ben's foreground interjection ("Sounds good") and excludes Ada's background host words.
        let fgHits = TranscriptSearch.matches(transcript.turns, query: "Sounds good")
        #expect(fgHits.count == 1)
        #expect(fgHits[0].turnID == mixed.id)
        let chars = Array(mixed.text)
        #expect(String(chars[fgHits[0].range]).lowercased() == "sounds good")
        #expect(TranscriptSearch.matches(transcript.turns, query: "release").isEmpty)
        #expect(TranscriptSearch.matches(transcript.turns, query: "download").isEmpty)

        // Library search (SearchFields) likewise preserves Ben's foreground interjection and excludes Ada's host speech.
        let fields = SearchFields(note)
        let soundsGoodQuery = try #require(SearchQuery("Sounds good"))
        #expect(fields.matches(soundsGoodQuery))
        #expect(!fields.matches(try #require(SearchQuery("release"))))
        #expect(!fields.matches(try #require(SearchQuery("download"))))

        // When BOTH host and inline speaker are background, the turn is fully background: folded and excluded from search.
        note.setSpeakerBackground("ben", true)
        let allBgTranscript = NoteTranscripts.sealed(note)
        let folded = TranscriptFolding.items(of: allBgTranscript.turns)
        let runs = folded.compactMap { item -> BackgroundTurnRun? in
            if case .backgroundRun(let run) = item { return run }
            return nil
        }
        #expect(runs.count == 1)
        #expect(runs[0].voiceCount == 2)
        #expect(TranscriptSearch.matches(allBgTranscript.turns, query: "Sounds good").isEmpty)
        #expect(!SearchFields(note).matches(soundsGoodQuery))
    }
}
