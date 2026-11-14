import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// D59 (amended after Android R9): words no speaker step told apart are one voice, an id new to the run (`<prefix>1`)
/// labelled "Speaker 1" in the user's language; "Unknown speaker" (`unassigned`) is left for a passage the user set to
/// no speaker.
@Suite struct OneVoiceTests {
    let stamp = VersionStamp(before: UUID(), after: UUID(), date: Date(timeIntervalSince1970: 1_000))
    static let run = "6F9619FF-8B86-D011-B42D-00C04FC964FF_"

    /// A transcription as the job saves it without a speaker step.
    func transcribed(language: String = "en", prefix: String = run) -> Note {
        let voice = NoteSpeaker.oneVoice(prefix: prefix, language: language)
        var note = Note(title: "Meeting")
        note.transcript = Note.oneVoice([TranscriptSegment(text: "Prima", start: 0, end: 4),
                                         TranscriptSegment(text: "Seconda", start: 5, end: 9)], voice)
        note.speakers = [voice]
        note.saveCurrentVersion(.transcription, id: UUID(), date: stamp.date)
        return note
    }

    @Test func theOneVoiceIsTheRunsFirstSpeakerInTheLanguageItIsWrittenIn() {
        #expect(NoteSpeaker.oneVoice(prefix: Self.run, language: "en") == NoteSpeaker(id: Self.run + "1", name: "Speaker 1", colourIndex: 0))
        #expect(NoteSpeaker.oneVoice(prefix: Self.run, language: "it").name == "Voce 1")
        #expect(NoteSpeaker.oneVoice(prefix: Self.run, language: "fr").name == "Intervenant 1")
        #expect(NoteSpeaker.oneVoice(prefix: Self.run, language: "pt-PT").name == "Orador 1")
        let note = transcribed(language: "it")
        #expect(note.transcript.allSatisfy { $0.speakerID == Self.run + "1" && $0.speaker == "Voce 1" })
        // Shown as stored (D47): an Italian label stays Italian in an English app.
        let turns = NoteTranscripts.sealed(note).turns
        #expect(turns.map(\.name) == [.placeholder(1, label: "Voce 1")])
        #expect(turns.allSatisfy { $0.speakerID == Self.run + "1" })
    }

    @Test func onlyAnUntouchedOneVoiceCountsAsOne() {
        let voice = NoteSpeaker.oneVoice(prefix: Self.run, language: "en")
        #expect([NoteSpeaker]().isOneVoice, "a note with no words, or as an older build stored it")
        #expect([voice].isOneVoice)
        #expect([NoteSpeaker.oneVoice(prefix: "other_", language: "es")].isOneVoice)
        var named = voice
        named.name = "Anna"
        #expect(![named].isOneVoice)
        var matched = voice
        matched.match = .suggested(voice: UUID(), score: 0.7)
        #expect(![matched].isOneVoice)
        var excluding = voice
        excluding.excludedVoiceIDs = [UUID()]
        #expect(![excluding].isOneVoice)
        #expect(![voice, NoteSpeaker(id: Self.run + "2", name: "Speaker 2")].isOneVoice)
        #expect([NoteSpeaker(id: "a", name: "Speaker 1")].isOneVoice, "a single unnamed voice a speaker step found")
    }

    /// The speaker step on a fresh one-voice transcription replaces the one voice in that version, as it did a
    /// transcription without speakers.
    @Test func anAnalysisReplacesTheOneVoiceInItsVersion() throws {
        var note = transcribed()
        let words = try #require(note.versions?.first?.id)
        note.applySpeakerAnalysis(turns: [.init(speakerID: "x", start: 0, end: 4.5), .init(speakerID: "y", start: 5, end: 9)],
                                  matches: [:], voiceNames: [:], autoName: true, stamp: stamp)
        #expect(note.transcript.map(\.speakerID) == ["x", "y"])
        #expect(note.speakers?.map(\.id) == ["x", "y"])
        #expect(note.versions?.map(\.id) == [words], "no version before or after the analysis")
        #expect(note.versions?.first?.speakers.map(\.id) == ["x", "y"])
    }

    /// A one voice the user named is theirs: the analysis keeps it as a version.
    @Test func anAnalysisKeepsANamedOneVoiceAsAVersion() {
        var note = transcribed()
        note.renameSpeaker(Self.run + "1", name: "Anna")
        note.applySpeakerAnalysis(turns: [.init(speakerID: "x", start: 0, end: 9)], matches: [:], voiceNames: [:],
                                  autoName: true, stamp: stamp)
        #expect(note.versions?.map(\.kind) == [.transcription, .speakerAnalysis])
        #expect(note.versions?.first?.speakers.map(\.name) == ["Anna"])
    }

    /// A passage the user sets to no speaker is the only one without a speaker: "Unknown speaker" on screen and
    /// `unassigned` in the exports, beside the one voice.
    @Test func aPassageSetToNoSpeakerIsUnassignedBesideTheOneVoice() {
        var note = transcribed()
        let original = note.transcript[1]
        let revised = original.revised(text: original.text, speakerID: nil, speakers: note.speakers ?? [])
        #expect(note.revisePassage(original, to: revised, stamp: stamp) == .saved)
        #expect(note.transcript.map(\.speakerID) == [Self.run + "1", nil])
        #expect(NoteTranscripts.sealed(note).turns.map(\.name) == [.placeholder(1, label: "Speaker 1"), .unknown])
        let export = ExportTranscript(note: note, unassignedLabel: "Unknown speaker")
        #expect(export.words.map(\.speaker) == [Self.run + "1", "unassigned"])
        #expect(export.labels[Self.run + "1"] == "Speaker 1")
        #expect(export.labels["unassigned"] == "Unknown speaker")
    }

    /// The draft shows words without a speaker as the job will save them: Speaker 1. Its header names nobody: the
    /// one voice has no id until the job saves the words, unlike a streamed draft speaker.
    @Test func aDraftWithoutSpeakersIsTheOneVoice() {
        let words = [DraftWord(speaker: "", startMs: 0, endMs: 800, text: "Hello"),
                     DraftWord(speaker: "", startMs: 1_000, endMs: 1_800, text: "everyone")]
        let turns = NoteTranscripts.draft(words, tentativeFromMs: nil).turns
        #expect(turns.map(\.speakerID) == [NoteTranscripts.draftOneVoice])
        #expect(turns.map(\.name) == [.placeholder(1, label: DefaultLabels.placeholder(1))])
        #expect(turns.map(\.nameableSpeakerID) == [nil])
        let streamed = NoteTranscripts.draft([DraftWord(speaker: Self.run + "1", startMs: 0, endMs: 800, text: "Hello")],
                                             tentativeFromMs: nil).turns
        #expect(streamed.map(\.nameableSpeakerID) == [Self.run + "1"])
        #expect(NoteTranscripts.sealed(transcribed()).turns.map(\.nameableSpeakerID) == [Self.run + "1"])
    }

    /// Android R9 and D56: each run's one voice has its own id, so the Cassini document of a note transcribed again
    /// keeps the earlier variant's speaker with its name, and the new variant's gets an entry of its own, "Speaker 1".
    @Test func transcribeAgainAddsItsOwnSpeakerToTheDocument() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("audio.opus")
        try Data(try PortableFixtures.silence()).write(to: source)
        var note = transcribed(prefix: "runA_")
        note.renameSpeaker("runA_1", name: "Ada")
        let first = directory.appendingPathComponent("first.opus")
        try PortableTranscript.export(note: note, opus: source, destination: first, unassignedLabel: "Unknown speaker")

        let again = NoteSpeaker.oneVoice(prefix: "runB_", language: "en")
        note.saveCurrentVersion(.previous)
        note.transcript = Note.oneVoice(note.transcript, again)
        note.speakers = [again]
        note.selectedVersionID = nil
        note.saveCurrentVersion(.transcription)
        let second = directory.appendingPathComponent("second.opus")
        try PortableTranscript.export(note: note, opus: first, destination: second, unassignedLabel: "Unknown speaker")

        let document = CassiniDocument.read(second)
        #expect(document.state == .ok)
        #expect(document.variants.count == 2)
        #expect(document.speakerLabel("runA_1") == "Ada", "the earlier run keeps its name")
        #expect(document.speakerLabel("runB_1") == "Speaker 1", "the new run inherits nothing")
        #expect(document.selected()?.transcript?.words.allSatisfy { $0.speaker == "runB_1" } == true)
    }
}
