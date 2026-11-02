import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// Transcribe again and Identify speakers again keep the names a note's speakers had, through note-local voices.
@Suite struct AnalysisMatchesTests {
    private let model = "m"
    private let stamp = VersionStamp(date: Date(timeIntervalSince1970: 1))

    private func print(_ speaker: String, _ vector: [Float], seconds: Double = 30) -> SpeakerPrint {
        SpeakerPrint(speakerID: speaker, model: model, vector: vector, speechSeconds: seconds)
    }

    /// A note whose earlier analysis gave "old_a" and "old_b", with "old_a" named Anna, then transcribed again: the
    /// words are new and the shown transcript is one voice, the run's "Speaker 1" (as `TranscriptionJob.saveTranscript`
    /// leaves it, D59).
    private func transcribedAgain(nameA: String = "Anna", matchA: VoiceMatchState = .unmatched) -> Note {
        var note = Note(title: "Riunione")
        note.transcript = [TranscriptSegment(text: "Prima", start: 0, end: 4, speakerID: "old_a"),
                           TranscriptSegment(text: "Seconda", start: 5, end: 9, speakerID: "old_b")]
        var anna = NoteSpeaker(id: "old_a", name: nameA)
        anna.match = matchA
        note.speakers = [anna, NoteSpeaker(id: "old_b", name: "Speaker 2")]
        note.refreshSpeakerLabels()
        note.saveCurrentVersion(.previous)
        let voice = NoteSpeaker.oneVoice(prefix: "run2_")
        note.transcript = Note.oneVoice([TranscriptSegment(text: "Nuova prima", start: 0, end: 4),
                                         TranscriptSegment(text: "Nuova seconda", start: 5, end: 9)], voice)
        note.speakers = [voice]
        note.selectedVersionID = nil
        note.saveCurrentVersion(.transcription)
        return note
    }

    private let turns = [SpeakerTurn(speakerID: "new_a", start: 0, end: 4.5), SpeakerTurn(speakerID: "new_b", start: 4.5, end: 9)]
    private let earlier: [SpeakerPrint] = [
        SpeakerPrint(speakerID: "old_a", model: "m", vector: [1, 0, 0], speechSeconds: 30),
        SpeakerPrint(speakerID: "old_b", model: "m", vector: [0, 1, 0], speechSeconds: 30),
    ]

    private func analysed(_ note: Note, saved: [SavedVoice] = [], trashed: Set<UUID> = [], autoName: Bool = false) -> Note {
        let prints = [print("new_a", [0.99, 0.05, 0]), print("new_b", [0.02, 0, 1])]
        let matching = AnalysisMatches.of(note, turns: turns, prints: prints, savedVoices: saved, earlierPrints: earlier,
                                          trashed: trashed)
        var copy = note
        matching.apply(to: &copy, turns: turns, autoName: autoName, stamp: stamp)
        return copy
    }

    // ports: TranscriptionJobTest#theJobNeverWritesDocumentOpus
    @Test func aNamedSpeakerKeepsItsNameOnTranscribeAgainWithAutomaticNamingOff() {
        let note = analysed(transcribedAgain())
        #expect(note.speakers?.map(\.name) == ["Anna", "Speaker 2"])
        #expect(note.transcript.map(\.speaker) == ["Anna", "Speaker 2"])
        // The match to a note-local voice is stored as no match, never as a link to a saved voice.
        #expect(note.speakers?.first?.match == .unmatched)
    }

    /// D59: the analysis attributes the one voice of Transcribe again in place, and finds the names in the latest
    /// version that told speakers apart, past another one-voice transcription.
    @Test func theOneVoiceOfTranscribeAgainIsAttributedInPlaceWithTheNamesBefore() {
        var note = transcribedAgain()
        let voice = NoteSpeaker.oneVoice(prefix: "run3_")
        note.transcript = Note.oneVoice([TranscriptSegment(text: "Terza prima", start: 0, end: 4),
                                         TranscriptSegment(text: "Terza seconda", start: 5, end: 9)], voice)
        note.speakers = [voice]
        note.selectedVersionID = nil
        note.saveCurrentVersion(.transcription)
        let again = analysed(note)
        #expect(again.speakers?.map(\.name) == ["Anna", "Speaker 2"])
        #expect(again.versions?.map(\.kind) == [.previous, .transcription, .transcription], "no version is added")
        #expect(again.versions?.last?.speakers.map(\.name) == ["Anna", "Speaker 2"])
        #expect(again.versions?[1].speakers == [.oneVoice(prefix: "run2_")], "the earlier transcription keeps its one voice")
    }

    @Test func placeholdersAndRejectedSpeakersDoNotCarryOver() {
        #expect(analysed(transcribedAgain(nameA: "Speaker 1")).speakers?.first?.name == "Speaker 1")
        let rejected = transcribedAgain(matchA: .rejected(voice: UUID(), score: 0.7))
        #expect(analysed(rejected).speakers?.first?.name == "Speaker 1")
    }

    @Test func aSpeakerLinkedToASavedVoiceMatchesThatVoiceInstead() {
        let other = UUID()
        let anna = SavedVoice(name: "Anna Rossi", samples: [VoiceSample(noteID: other, print: print("x", [1, 0, 0]))])
        let note = transcribedAgain(matchA: .confirmed(voice: anna.id, score: 0.9))
        let matching = AnalysisMatches.of(note, turns: turns, prints: [print("new_a", [0.99, 0.05, 0])], savedVoices: [anna],
                                          earlierPrints: earlier, trashed: [])
        #expect(matching.localVoices.isEmpty, "the saved voice matches on its own")
        #expect(matching.matches["new_a"]?.voiceID == anna.id)
        #expect(analysed(note, saved: [anna], autoName: true).speakers?.first?.name == "Anna Rossi")
        // A saved voice whose samples are all in Recently Deleted matches nothing.
        #expect(analysed(note, saved: [anna], trashed: [other], autoName: true).speakers?.first?.name == "Speaker 1")
    }

    @Test func aSpeakerRememberedFromThisNoteAloneKeepsItsNameAndLink() {
        // "Remember this voice" in this note: the voice's only sample is this note's print of the speaker.
        let annaID = UUID()
        let note = transcribedAgain(nameA: "Anna Rossi", matchA: .confirmed(voice: annaID, score: 0.9))
        let anna = SavedVoice(id: annaID, name: "Anna Rossi",
                              samples: [VoiceSample(noteID: note.id, print: print("old_a", [1, 0, 0]))])
        let again = analysed(note, saved: [anna], autoName: false)
        #expect(again.speakers?.map(\.name) == ["Anna Rossi", "Speaker 2"])
        if case .confirmed(let voice, _) = again.speakers?.first?.match { #expect(voice == annaID) }
        else { Issue.record("expected a confirmed link") }
    }

    @Test func aSpeakerConfirmedToAVoiceOfOtherNotesKeepsItsNameWithAutomaticNamingOff() {
        let anna = SavedVoice(name: "Anna Rossi", samples: [VoiceSample(noteID: UUID(), print: print("x", [1, 0, 0]))])
        let note = transcribedAgain(nameA: "Anna Rossi", matchA: .confirmed(voice: anna.id, score: 0.9))
        let again = analysed(note, saved: [anna], autoName: false)
        #expect(again.speakers?.first?.name == "Anna Rossi")
        if case .confirmed(let voice, _) = again.speakers?.first?.match { #expect(voice == anna.id) }
        else { Issue.record("expected a confirmed link") }
        // An unlinked note that only resembles the voice gets a suggestion, as before.
        #expect(analysed(transcribedAgain(nameA: "Speaker 1"), saved: [anna]).speakers?.first?.match
            == .suggested(voice: anna.id, score: again.speakers?.first?.match.score ?? 0))
    }

    @Test func anAutomaticLinkComesBackAsAutomatic() {
        let anna = SavedVoice(name: "Anna Rossi", samples: [VoiceSample(noteID: UUID(), print: print("x", [1, 0, 0]))])
        let note = transcribedAgain(nameA: "Anna Rossi", matchA: .auto(voice: anna.id, score: 0.9))
        let again = analysed(note, saved: [anna], autoName: false)
        #expect(again.speakers?.first?.name == "Anna Rossi")
        if case .auto(let voice, _) = again.speakers?.first?.match { #expect(voice == anna.id) }
        else { Issue.record("expected an automatic link") }
    }

    @Test func identifySpeakersAgainCarriesTheShownNames() {
        var note = Note(title: "Riunione")
        note.transcript = [TranscriptSegment(text: "Prima", start: 0, end: 4, speakerID: "old_a"),
                           TranscriptSegment(text: "Seconda", start: 5, end: 9, speakerID: "old_b")]
        note.speakers = [NoteSpeaker(id: "old_a", name: "Giulia"), NoteSpeaker(id: "old_b", name: "Marco")]
        let again = analysed(note)
        #expect(again.speakers?.map(\.name) == ["Giulia", "Speaker 2"], "Marco's voice is not like the new speaker's")
        #expect(again.versions?.count == 2)
    }

    @Test func withoutEarlierPrintsNothingCarriesOver() {
        let note = transcribedAgain()
        let matching = AnalysisMatches.of(note, turns: turns, prints: [print("new_a", [1, 0, 0])], savedVoices: [],
                                          earlierPrints: [], trashed: [])
        #expect(matching.matches.isEmpty && matching.localVoices.isEmpty)
    }
}
