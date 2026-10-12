import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct VoiceCodecTests {
    typealias F = VoiceFixtures

    // ports: VoiceCodecTest#voicesRoundTripThroughVersionOne
    @Test func voicesRoundTripThroughVersionOne() throws {
        let (voices, anna) = VoiceCodec.enrol([], voiceID: nil, name: "Anna", noteID: UUID(),
                                              print: F.print("s", [3, 4, 0], seconds: 12.5), newID: F.id("anna"))
        let data = try VoiceCodec.encode(voices)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let back = try #require(VoiceCodec.decode(data).first)
        #expect(back.id == anna.id)
        #expect(back.samples.first?.print.vector == [3, 4, 0])
        #expect(abs(try #require(back.mean(model: F.model, dimension: 3))[0] - 0.6) < 1e-6)
    }

    // ports: VoiceCodecTest#anotherVersionIsRefusedWithItsNumber
    @Test func anotherVersionIsRefusedWithItsNumber() {
        #expect(throws: UnsupportedVoiceFileVersion(found: 2, supported: 1)) {
            try VoiceCodec.decode(Data(#"{"version":2,"voices":[]}"#.utf8))
        }
    }

    /// iOS: before the version field, voices.json was a bare array.
    @Test func theLegacyBareArrayStillReads() throws {
        let voice = F.voice("anna", "Anna")
        let legacy = try JSONEncoder().encode([voice])
        #expect(try VoiceCodec.decode(legacy) == [voice])
        #expect(throws: DecodingError.self) { try VoiceCodec.decode(Data("{not json".utf8)) }
    }

    // ports: VoiceCodecTest#unenrolInvertsTheRunningMean
    /// iOS keeps the samples rather than a running mean: unenrol removes exactly the sample it enrolled.
    @Test func unenrolRemovesExactlyOneSample() throws {
        let first = UUID(), second = UUID()
        let (once, anna) = VoiceCodec.enrol([], voiceID: nil, name: "Anna", noteID: first, print: F.print("s1", F.axis(0)), newID: F.id("anna"))
        let (twice, _) = VoiceCodec.enrol(once, voiceID: anna.id, name: "Anna", noteID: second, print: F.print("s2", F.axis(1)), newID: UUID())
        #expect(twice.first?.samples.count == 2)
        let back = VoiceCodec.unenrol(twice, voiceID: anna.id, noteID: second, speakerID: "s2")
        #expect(back.outcome == .unenrolled)
        #expect(back.voices == once)
        let mean = try #require(back.voices.first?.mean(model: F.model, dimension: F.dimension))
        #expect(abs(mean[0] - 1) < 1e-5 && abs(mean[1]) < 1e-5)
        #expect(VoiceCodec.unenrol(twice, voiceID: anna.id, noteID: UUID(), speakerID: "s2").outcome == .nothingToUndo)
        let last = VoiceCodec.unenrol(once, voiceID: anna.id, noteID: first, speakerID: "s1")
        #expect(last.outcome == .forgotten)
        #expect(last.voices.isEmpty, "a voice without samples is forgotten")
    }

    /// Enrolling the same note and speaker again replaces its sample, never counting it twice.
    @Test func enrollingTheSameSpeakerAgainReplacesItsSample() {
        let note = UUID()
        let (once, anna) = VoiceCodec.enrol([], voiceID: nil, name: "Anna", noteID: note, print: F.print("s", F.axis(0)), newID: F.id("anna"))
        let (again, renamed) = VoiceCodec.enrol(once, voiceID: anna.id, name: "Anna R.", noteID: note, print: F.print("s", F.axis(1)), newID: UUID())
        #expect(again.count == 1)
        #expect(renamed.samples.map(\.print.vector) == [F.axis(1)])
        #expect(renamed.name == "Anna R.")
    }

    // ports: NoteVoiceCodecTest#printsAndMatchesRoundTripThroughVersionTwo
    /// iOS: version 1, prints only (the matches are in the note's speakers).
    @Test func printsRoundTripThroughVersionOne() throws {
        let prints = [F.print("tr_S1", [1, 0], seconds: 10), F.print("tr_S2", [0, 1], seconds: 3)]
        let data = try NoteVoiceCodec.encode(prints)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(try NoteVoiceCodec.decode(data) == prints)
        #expect(try NoteVoiceCodec.decode(JSONEncoder().encode(prints)) == prints, "the bare array of before still reads")
    }

    // ports: NoteVoiceCodecTest#aVersionMismatchThrowsAndSaysWhetherTheFileIsNewer
    @Test func aVersionMismatchThrowsAndSaysWhetherTheFileIsNewer() {
        do {
            _ = try NoteVoiceCodec.decode(Data(#"{"version":3,"prints":[]}"#.utf8))
            Issue.record("a newer file was read")
        } catch let error as UnsupportedVoiceFileVersion {
            #expect(error.found == 3)
            #expect(error.newer)
        } catch { Issue.record("\(error)") }
        do {
            _ = try NoteVoiceCodec.decode(Data(#"{"version":0,"prints":[]}"#.utf8))
            Issue.record("an older file was read")
        } catch let error as UnsupportedVoiceFileVersion {
            #expect(!error.newer)
        } catch { Issue.record("\(error)") }
    }

    // ports: NoteVoiceCodecTest#meetingAndVariantIdsCannotEscapeTheirPlace
    @Test func onlyNoteFileNamesAreNotePrints() {
        let id = UUID()
        #expect(NoteVoiceCodec.fileName(id) == id.uuidString + ".json")
        #expect(NoteVoiceCodec.noteID(fileName: id.uuidString + ".json") == id)
        #expect(NoteVoiceCodec.noteID(fileName: "voices.json") == nil)
        #expect(NoteVoiceCodec.noteID(fileName: "../" + id.uuidString + ".json") == nil)
        #expect(NoteVoiceCodec.noteID(fileName: id.uuidString.lowercased() + ".json") == nil, "only the name Cassini writes")
        #expect(NoteVoiceCodec.noteID(fileName: "") == nil)
    }
}
