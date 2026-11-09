import Foundation
import Testing
import CassiniCore
@testable import CassiniNotebook

@Suite struct WordTimingProvenanceTests {
    private func imported(marker: String?) throws -> PortableTranscript {
        let bytes = try PortableFixtures.document([Word("ada", 0, 5000, "Wait.")], title: "Timing provenance", labels: ["ada": "Ada"])
        var document = CassiniDocument.read(bytes)
        if let marker {
            document.manifest?["provenance"] = .object(try JSON.parseObject("{\"wordTimings\":{\"endsBoundedByAudio\":\(marker)}}"))
        }
        return try #require(PortableTranscript(document))
    }

    // loadArtifact.ts readWordEndsBoundedByAudio accepts literal boolean true only.
    @Test(arguments: ["true", "false", "\"true\"", "1", "null"])
    func importRetainsOnlyLiteralTrue(_ marker: String) throws {
        let portable = try imported(marker: marker)
        #expect(!portable.segments.isEmpty)
        #expect(portable.segments.allSatisfy { $0.wordEndsBoundedByAudio == (marker == "true" ? true : nil) })
    }

    @Test func missingProvenanceKeepsLegacyRepair() throws {
        let portable = try imported(marker: nil)
        #expect(portable.segments.allSatisfy { $0.wordEndsBoundedByAudio == nil })
        let words = portable.segments.flatMap(\.words).map {
            TurnModel.Word(speaker: "ada", startMs: $0.start * 1000, endMs: $0.end * 1000, text: $0.text)
        }
        #expect(try #require(TurnModel.rows(of: words).first).endMs == 1000)
    }

    @Test func importedProvenanceSurvivesNoteStorageAndBypassesRepair() throws {
        let portable = try imported(marker: "true")
        var note = Note(title: "Timing provenance")
        note.transcript = portable.segments
        note.speakers = portable.speakers
        note.versions = portable.versions
        note.selectedVersionID = portable.selectedVersionID
        let restored = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(restored.transcript == note.transcript)
        #expect(restored.versions == note.versions)
        let export = ExportTranscript(note: restored, unassignedLabel: "Unknown speaker")
        #expect(export.endsBoundedByAudio)
        let words = export.words.map {
            TurnModel.Word(speaker: $0.speaker, startMs: Double($0.startMs), endMs: Double($0.endMs), text: $0.text)
        }
        #expect(try #require(TurnModel.rows(of: words, endsBoundedByAudio: export.endsBoundedByAudio).first).endMs == 5000)
    }

    @Test func exportUsesTheRequestedVersionAndRequiresEverySegmentToVouch() throws {
        var note = Note(title: "Version timing")
        note.transcript = try imported(marker: "true").segments
        let unmarked = TranscriptSegment(text: "Later.", start: 10, end: 15)
        let version = TranscriptVersion(kind: .previous, segments: [unmarked], speakers: [])
        #expect(ExportTranscript(note: note, unassignedLabel: "Unknown").endsBoundedByAudio)
        #expect(!ExportTranscript(note: note, version: version, unassignedLabel: "Unknown").endsBoundedByAudio)
        note.transcript.append(unmarked)
        #expect(!ExportTranscript(note: note, unassignedLabel: "Unknown").endsBoundedByAudio)
        note.transcript = []
        #expect(!ExportTranscript(note: note, unassignedLabel: "Unknown").endsBoundedByAudio)
        #expect(!ExportTranscript(title: "Empty", durationMs: 0, words: [], labels: [:]).endsBoundedByAudio)
    }

    @Test func editingTextClearsTimingEvidenceButRenamingKeepsIt() throws {
        let segment = try #require(imported(marker: "true").segments.first)
        let speakers = [NoteSpeaker(id: "ada", name: "Ada")]
        #expect(segment.revised(text: segment.text, speakerID: "ada", speakers: speakers).wordEndsBoundedByAudio == true)
        let edited = segment.revised(text: "Changed.", speakerID: "ada", speakers: speakers)
        #expect(edited.words.isEmpty)
        #expect(edited.wordEndsBoundedByAudio == nil)
    }

    @Test func oldSegmentAndWordJSONRemainReadable() throws {
        let old = """
        {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","text":"Wait.","start":0,"end":5,
         "words":[{"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","text":"Wait.","start":0,"end":5}]}
        """
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(old.utf8))
        #expect(segment.wordEndsBoundedByAudio == nil)
        #expect(segment.words.first?.lowConfidenceSpeaker == nil)
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(segment)) == segment)
    }
}
