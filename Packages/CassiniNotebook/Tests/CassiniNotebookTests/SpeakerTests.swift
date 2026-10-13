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
