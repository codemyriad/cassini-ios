import Foundation
import Testing
@testable import CassiniNotebook

/// The note side of naming and analysis: what a speaker analysis keeps, rejections, merges and the naming commit.
@Suite struct NoteVoicesTests {
    typealias F = VoiceFixtures
    let stamp = VersionStamp(before: F.id("before"), after: F.id("after"), date: Date(timeIntervalSince1970: 1_000))

    func conversation() -> Note {
        var note = Note(title: "Conversation")
        note.transcript = [TranscriptSegment(text: "First", start: 0, end: 4), TranscriptSegment(text: "Second", start: 5, end: 9)]
        return note
    }

    @Test func anAnalysisNumbersSpeakersByFirstPassageAndKeepsTheTranscriptBefore() throws {
        var note = conversation()
        let luca = F.voice("luca", "Luca")
        note.applySpeakerAnalysis(turns: [.init(speakerID: "y", start: 5, end: 9), .init(speakerID: "x", start: 0, end: 4.5)],
                                  matches: ["y": VoiceMatch(voiceID: luca.id, score: 0.7, automatic: false)],
                                  voiceNames: [luca.id: luca.name], autoName: true, stamp: stamp)
        #expect(note.speakers?.map(\.id) == ["x", "y"])
        #expect(note.transcript.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(note.speakers?[1].match == .suggested(voice: luca.id, score: 0.7))
        #expect(note.versions?.map(\.name) == ["Before speaker analysis", "Speaker analysis"])
        #expect(note.versions?.map(\.id) == [stamp.before, stamp.after])
        #expect(note.selectedVersionID == stamp.after)
        #expect(note.speakerAnalysisFailure == nil)
    }

    @Test func anAutomaticMatchNamesTheSpeakerOnlyWhenAutomaticNamingIsOn() {
        let luca = F.voice("luca", "Luca")
        let match = ["x": VoiceMatch(voiceID: luca.id, score: 0.9, automatic: true)]
        var on = conversation(), off = conversation()
        let turns = [SpeakerTurn(speakerID: "x", start: 0, end: 9)]
        on.applySpeakerAnalysis(turns: turns, matches: match, voiceNames: [luca.id: "Luca"], autoName: true, stamp: stamp)
        off.applySpeakerAnalysis(turns: turns, matches: match, voiceNames: [luca.id: "Luca"], autoName: false, stamp: stamp)
        #expect(on.speakers?.first?.name == "Luca")
        #expect(on.speakers?.first?.match == .auto(voice: luca.id, score: 0.9))
        #expect(off.speakers?.first?.name == "Speaker 1")
        #expect(off.speakers?.first?.match == .suggested(voice: luca.id, score: 0.9))
    }

    /// The acceptance case of the plan: a voice rejected for a speaker is not offered again after Identify speakers.
    @Test func aRejectedVoiceStaysRejectedAcrossAnotherAnalysis() throws {
        var note = conversation()
        let luca = F.voice("luca", "Luca")
        note.applySpeakerAnalysis(turns: [.init(speakerID: "p1_a", start: 0, end: 4.5), .init(speakerID: "p1_b", start: 4.5, end: 9)],
                                  matches: ["p1_b": VoiceMatch(voiceID: luca.id, score: 0.7, automatic: false)],
                                  voiceNames: [luca.id: "Luca"], autoName: false, stamp: stamp)
        note.rejectVoice(luca.id, for: "p1_b", restorePlaceholder: false)
        #expect(note.speakers?[1].match == .rejected(voice: luca.id, score: 0.7))

        let again = [SpeakerTurn(speakerID: "p2_a", start: 0, end: 4.2), SpeakerTurn(speakerID: "p2_b", start: 4.2, end: 9)]
        let excluded = note.carriedExclusions(for: again)
        #expect(excluded == ["p2_b": [luca.id]])
        // The matcher honours the exclusion, and the note keeps it even when a match slipped through.
        let prints = [F.print("p2_b", F.axis(0))]
        #expect(VoiceMatcher.match(prints: prints, voices: [luca], excluded: excluded).isEmpty)
        note.applySpeakerAnalysis(turns: again, matches: ["p2_b": VoiceMatch(voiceID: luca.id, score: 0.9, automatic: true)],
                                  voiceNames: [luca.id: "Luca"], autoName: true,
                                  stamp: VersionStamp(date: Date(timeIntervalSince1970: 2_000)))
        #expect(note.speakers?[1].excludedVoiceIDs == [luca.id])
        #expect(note.speakers?[1].match == .unmatched)
        #expect(note.speakers?[1].name == "Speaker 2")
    }

    @Test func notThisPersonReturnsTheVoicesNameToThePlaceholder() {
        var note = conversation()
        note.speakers = [NoteSpeaker(id: "a", name: "Luca", match: .auto(voice: F.id("luca"), score: 0.9))]
        note.transcript[0].speakerID = "a"
        note.rejectVoice(F.id("luca"), for: "a", restorePlaceholder: true)
        #expect(note.transcript[0].speaker == "Speaker 1")
        #expect(note.speakers?[0].excludedVoiceIDs == [F.id("luca")])
    }

    @Test func aMergeKeepsAVersionAndLinksTheTargetOnlyAutomatically() throws {
        var note = conversation()
        note.speakers = [NoteSpeaker(id: "a", name: "Anna", match: .confirmed(voice: F.id("anna"), score: 0.8)),
                         NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript[0].speakerID = "a"; note.transcript[1].speakerID = "b"
        note.refreshSpeakerLabels()
        #expect(note.mergeVersionNumbers == (1, 2))
        note.mergeSpeaker("b", into: "a", stamp: stamp)
        #expect(note.transcript.map(\.speaker) == ["Anna", "Anna"])
        #expect(note.speakers?.map(\.id) == ["a"])
        #expect(note.speakers?[0].match == .auto(voice: F.id("anna"), score: 0.8))
        #expect(note.versions?.map(\.id) == [stamp.before, stamp.after])
        #expect(note.versions?[0].speakers[0].match == .confirmed(voice: F.id("anna"), score: 0.8), "the confirmation stays with its version")
        #expect(note.mergeVersionNumbers == (2, 3))
    }

    @Test func forgettingAVoiceDropsItsLinksInEveryVersionButKeepsNamesAndRejections() {
        var note = conversation()
        let anna = F.id("anna")
        var rejected = NoteSpeaker(id: "b", name: "Speaker 2", match: .rejected(voice: anna, score: 0.6))
        rejected.excludedVoiceIDs = [anna]
        note.speakers = [NoteSpeaker(id: "a", name: "Anna", match: .confirmed(voice: anna, score: 0.8)), rejected]
        note.saveCurrentVersion(name: "Named", id: stamp.before, date: stamp.date)
        note.unlinkVoice(anna)
        #expect(note.speakers?.map(\.match) == [.unmatched, .rejected(voice: anna, score: 0.6)])
        #expect(note.speakers?[0].name == "Anna")
        #expect(note.versions?[0].speakers[0].match == .unmatched)
        var other = conversation()
        other.speakers = [NoteSpeaker(id: "a", name: "Anna", match: .suggested(voice: anna, score: 0.7))]
        other.reconcileVoices([F.id("luca")])
        #expect(other.speakers?[0].match == .unmatched)
    }

    // MARK: - NamingCommit

    @Test func rememberingEnrolsTheSampleAndConfirmsTheSpeaker() {
        let noteID = UUID()
        let speaker = NoteSpeaker(id: "s3", name: "Speaker 3")
        let print = F.print("s3", F.axis(0))
        let commit = NamingCommit.plan([.relabel(speakerID: "s3", name: "Giorgio"), .rememberVoice(speakerID: "s3", voiceID: nil, name: "Giorgio")],
                                       noteID: noteID, speaker: speaker, print: print, voices: [], voicesReadOnly: false,
                                       newVoiceID: F.id("giorgio"))
        #expect(commit.voices == [SavedVoice(id: F.id("giorgio"), name: "Giorgio", samples: [VoiceSample(noteID: noteID, print: print)])])
        #expect(commit.changes == [.rename(speakerID: "s3", name: "Giorgio"), .match(speakerID: "s3", .confirmed(voice: F.id("giorgio"), score: 1))])
        #expect(commit.changesVoices && commit.refused == nil)
    }

    @Test func notThisPersonOnTheOnlySampleForgetsTheVoiceEverywhere() {
        let noteID = UUID()
        let anna = SavedVoice(id: F.id("anna"), name: "Anna", samples: [VoiceSample(noteID: noteID, print: F.print("s3", F.axis(0)))])
        let speaker = NoteSpeaker(id: "s3", name: "Anna", match: .confirmed(voice: anna.id, score: 1))
        let commit = NamingCommit.plan([.reject(speakerID: "s3", voiceID: anna.id, voiceName: "Anna", unenrol: true, restorePlaceholder: true)],
                                       noteID: noteID, speaker: speaker, print: nil, voices: [anna], voicesReadOnly: false)
        #expect(commit.voices.isEmpty)
        #expect(commit.forgotten == [anna.id])
        #expect(commit.changes == [.reject(speakerID: "s3", voiceID: anna.id, restorePlaceholder: true), .unlinkVoice(anna.id)])
    }

    @Test func voiceChangesAreRefusedWhileTheVoicesCannotBeChangedOrWithoutAPrint() {
        let speaker = NoteSpeaker(id: "s3", name: "Speaker 3")
        let remember: [NamingEffect] = [.rememberVoice(speakerID: "s3", voiceID: nil, name: "Bea")]
        #expect(NamingCommit.plan(remember, noteID: UUID(), speaker: speaker, print: F.print("s3", F.axis(0)), voices: [],
                                  voicesReadOnly: true).refused == .readOnly)
        #expect(NamingCommit.plan(remember, noteID: UUID(), speaker: speaker, print: F.print("s3", F.axis(0), seconds: 3), voices: [],
                                  voicesReadOnly: false).refused == .noPrint)
        let relabel = NamingCommit.plan([.relabel(speakerID: "s3", name: "Bea")], noteID: UUID(), speaker: speaker, print: nil,
                                        voices: [], voicesReadOnly: true)
        #expect(relabel.refused == nil, "a name alone needs no saved voice")
    }

    @Test func applyingTheChangesTwiceGivesTheSameNote() {
        var note = conversation()
        note.speakers = [NoteSpeaker(id: "a", name: "Speaker 1"), NoteSpeaker(id: "b", name: "Speaker 2")]
        note.transcript[0].speakerID = "a"; note.transcript[1].speakerID = "b"
        let changes: [SpeakerChange] = [.rename(speakerID: "a", name: "Anna"), .merge(source: "b", target: "a", stamp: stamp)]
        var once = note, twice = note
        once.apply(changes)
        twice.apply(changes)
        #expect(once == twice)
        #expect(once.transcript.map(\.speaker) == ["Anna", "Anna"])
    }
}
