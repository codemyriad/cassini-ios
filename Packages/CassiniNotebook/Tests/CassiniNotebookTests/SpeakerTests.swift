import Foundation
import Testing
@testable import CassiniNotebook

@Test func speakerRenameAndMergeAreConsistentAndReversible() throws {
    var note = Note(title: "Conversation")
    note.transcript = [.init(text: "First", start: 0, end: 1, speaker: "Alex"), .init(text: "Second", start: 1, end: 2, speaker: "Sam"), .init(text: "Third", start: 2, end: 3, speaker: "Alex")]
    note.migrateSpeakers()
    let a = try #require(note.speakers?.first?.id), b = try #require(note.speakers?.last?.id)
    note.renameSpeaker(a, name: "Alice")
    #expect(note.transcript.map(\.speaker) == ["Alice", "Sam", "Alice"])
    note.mergeSpeaker(b, into: a)
    #expect(note.speakers?.count == 1)
    #expect(note.transcript.allSatisfy { $0.speaker == "Alice" })
    let before = try #require(note.versions?.first?.id)
    note.selectVersion(before)
    #expect(note.transcript.map(\.speaker) == ["Alice", "Sam", "Alice"])
    #expect(note.versions?.count == 2)
}

@Test func aMergeRecordsItsAliasAndTheVersionItWasMadeFrom() throws {
    var note = Note(title: "Conversation")
    note.transcript = [.init(text: "First", start: 0, end: 1, speakerID: "a"), .init(text: "Second", start: 1, end: 2, speakerID: "b"),
                       .init(text: "Third", start: 2, end: 3, speakerID: "c")]
    note.speakers = [NoteSpeaker(id: "a", name: "A"), NoteSpeaker(id: "b", name: "B"), NoteSpeaker(id: "c", name: "C")]
    note.mergeSpeaker("b", into: "a")
    let first = try #require(note.versions?.first)
    let merged = try #require(note.versions?.last)
    #expect(first.speakerMerges == nil)
    #expect(merged.speakerMerges == ["b": "a"])
    #expect(merged.derivedFrom == first.id)
    // A second merge starts from the merged version, which is the one shown.
    note.mergeSpeaker("c", into: "a")
    let again = try #require(note.versions?.last)
    #expect(note.versions?.count == 3)
    #expect(again.speakerMerges == ["c": "a"])
    #expect(again.derivedFrom == merged.id)
}

@Test func anEditOfAMergedVersionKeepsTheMerge() throws {
    var note = Note(title: "Conversation")
    note.transcript = [.init(text: "First", start: 0, end: 1, speakerID: "a"), .init(text: "Second", start: 1, end: 2, speakerID: "b")]
    note.speakers = [NoteSpeaker(id: "a", name: "A"), NoteSpeaker(id: "b", name: "B")]
    note.mergeSpeaker("b", into: "a")
    let merged = try #require(note.versions?.last)
    let original = try #require(note.transcript.last)
    note.revisePassage(original, to: original.revised(text: "Second, edited", speakerID: "a", speakers: note.speakers ?? []),
                       stamp: VersionStamp(date: Date()))
    let edited = try #require(note.versions?.last)
    #expect(edited.id == note.selectedVersionID && edited.id != merged.id)
    #expect(edited.speakerMerges == ["b": "a"])
    #expect(edited.derivedFrom == merged.derivedFrom)
    // A version kept of the edited transcript (before an export, say) keeps it too.
    note.transcript[0].text = "First, edited"
    note.saveCurrentVersion(.editedTranscript)
    #expect(note.versions?.last?.speakerMerges == ["b": "a"])
}

@Test func trashUsesCalendarDaysAcrossDSTAndClockRollback() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let deleted = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 23)))
    let expiry = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
    #expect(TrashPolicy.daysLeft(since: deleted, now: expiry, calendar: calendar) == 0)
    #expect(TrashPolicy.daysLeft(since: deleted, now: expiry.addingTimeInterval(-1), calendar: calendar) == 1)
    #expect(TrashPolicy.daysLeft(since: deleted, now: deleted.addingTimeInterval(-86400), calendar: calendar) == 30)
}

@Test func transcriptExportNeverContainsVoiceLinksOrPrivateEvidence() throws {
    var note = Note(title: "Privacy")
    var speaker = NoteSpeaker(id: "speaker", name: "Alex")
    let privateID = UUID(); speaker.match = .confirmed(voice: privateID, score: 0.9); speaker.excludedVoiceIDs = [privateID]
    note.speakers = [speaker]
    note.transcript = [.init(text: "Hello", start: 0, end: 1, speaker: "Alex", speakerID: "speaker")]
    note.saveCurrentVersion(.transcription)
    let json = String(decoding: try JSONExport.data(note), as: UTF8.self)
    #expect(!json.contains(privateID.uuidString))
    #expect(!json.contains("vector"))
    #expect(json.contains("Alex"))
}

@Test func versionOneNotesStillDecodeWithoutSpeakerFields() throws {
    let note = Note(title: "Legacy")
    let data = try JSONEncoder().encode(note)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["speakers", "versions", "selectedVersionID", "speakerAnalysisMessage", "originalAudioFilename"] { object.removeValue(forKey: key) }
    let decoded = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.title == "Legacy")
    #expect(decoded.speakers == nil)
    #expect(decoded.originalAudioFilename == nil)
}

@Test func editingAnImportedVersionPreservesTheOriginalSnapshot() throws {
    var note = Note(title: "History")
    note.transcript = [.init(text: "Original", start: 0, end: 1)]
    note.saveCurrentVersion(.imported)
    let original = try #require(note.selectedVersionID)
    note.transcript[0].text = "Edited"
    note.saveCurrentVersion(.editedPassages)
    #expect(note.versions?.count == 2)
    note.selectVersion(original)
    #expect(note.text == "Original")
    #expect(note.versions?.last?.segments.first?.text == "Edited")
}

/// D53.2: a version keeps the language of its words. A merge and a passage edit keep the language of the words they
/// came from; selecting a version brings its language back; the language survives a save and a reload.
@Test func eachVersionKeepsTheLanguageOfItsWords() throws {
    var note = Note(title: "Languages")
    note.transcript = [.init(text: "Hello", start: 0, end: 1, speakerID: "a"), .init(text: "everyone", start: 1, end: 2, speakerID: "b")]
    note.speakers = [NoteSpeaker(id: "a", name: "A"), NoteSpeaker(id: "b", name: "B")]
    note.language = "it-IT"
    note.saveCurrentVersion(.transcription)
    let apple = try #require(note.selectedVersionID)

    note.mergeSpeaker("b", into: "a")
    #expect(note.language == "it-IT")
    #expect(note.versions?.last?.language == "it-IT", "a merge keeps the language of the words it came from")
    let original = try #require(note.transcript.last)
    note.revisePassage(original, to: original.revised(text: "everyone here", speakerID: "a", speakers: note.speakers ?? []),
                       stamp: VersionStamp(date: Date()))
    #expect(note.versions?.last?.kind == .editedPassages)
    #expect(note.versions?.last?.language == "it-IT", "a passage edit keeps it too")

    // A later Parakeet run: its words are `und`.
    note.saveCurrentVersion(.previous)
    note.transcript = [.init(text: "Hello", start: 0, end: 1)]
    note.speakers = []
    note.language = TranscriptLanguage.undetermined
    note.selectedVersionID = nil
    note.saveCurrentVersion(.transcription)
    let parakeet = try #require(note.selectedVersionID)
    #expect(note.versions?.last?.language == "und")

    note.selectVersion(apple)
    #expect(note.language == "it-IT")
    note.selectVersion(parakeet)
    #expect(note.language == "und")

    let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
    #expect(decoded.versions?.map(\.language) == note.versions?.map(\.language))
    #expect(decoded.language == "und")
}

/// A version without a stored language (written before versions had one) reads as unknown: no migration (D51).
@Test func aVersionWithoutALanguageReadsAsUnknown() throws {
    let version = TranscriptVersion(kind: .transcription, segments: [.init(text: "x", start: 0, end: 1)], speakers: [])
    let data = try JSONEncoder().encode(version)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["language"] == nil, "an empty language is left out")
    #expect(try JSONDecoder().decode(TranscriptVersion.self, from: data).language == "")
}
