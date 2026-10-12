import Foundation
import Testing
@testable import CassiniNotebook

@Test func diarizationSplitsWordsWithoutChangingOrderOrTimestamps() {
    let words = [TimedWord(text: "Hello ", start: 0, end: 1), TimedWord(text: "Sam. ", start: 1, end: 2), TimedWord(text: "Hi!", start: 2, end: 3)]
    let input = [TranscriptSegment(text: "Hello Sam. Hi!", start: 0, end: 3, words: words)]
    let output = SpeakerAttribution.assign(input, turns: [.init(speakerID: "a", start: 0, end: 1.8), .init(speakerID: "b", start: 1.8, end: 3)])
    #expect(output.map(\.speakerID) == ["a", "b"])
    #expect(output.flatMap(\.words) == words)
    #expect(output.map(\.text) == ["Hello Sam.", "Hi!"])
    let uncovered = SpeakerAttribution.assign(input, turns: [])
    #expect(uncovered.allSatisfy { $0.speakerID == nil })
    #expect(uncovered.flatMap(\.words) == words)
}

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

@Test func voiceMatchingRejectsInvalidDifferentModelsAndAmbiguousIdentities() throws {
    let print = SpeakerPrint(speakerID: "speaker", model: "ios-v1", vector: [1, 0], speechSeconds: 10)
    let voice = SavedVoice(name: "Alex", samples: [.init(noteID: UUID(), print: print)])
    #expect(VoiceMatcher.match(prints: [print], voices: [voice])["speaker"]?.automatic == true)
    #expect(VoiceMatcher.match(prints: [print], voices: [voice], excluded: ["speaker": [voice.id]]).isEmpty)
    var otherModel = print; otherModel.model = "android-cam++"
    #expect(VoiceMatcher.match(prints: [otherModel], voices: [voice]).isEmpty)
    var short = print; short.speechSeconds = 2
    #expect(VoiceMatcher.match(prints: [short], voices: [voice]).isEmpty)
    let twin = SavedVoice(name: "Similar voice", samples: voice.samples)
    #expect(VoiceMatcher.match(prints: [print], voices: [voice, twin])["speaker"]?.automatic == false)
    var second = print; second.speakerID = "another"
    let matches = VoiceMatcher.match(prints: [print, second], voices: [voice])
    #expect(matches.count == 1)
    #expect(matches.values.allSatisfy { !$0.automatic })
    #expect(VoiceMatcher.normalized([.nan, 0]) == nil)
    #expect(VoiceMatcher.normalized([0, 0]) == nil)
}

@Test func deletingRecordingRemovesItsVoiceEvidenceAndKeepsOtherSamples() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try VoiceLibrary(root: root), id = UUID(), otherID = UUID()
    let print = SpeakerPrint(speakerID: "speaker", model: "ios-v1", vector: [1, 0], speechSeconds: 10)
    try library.save([SavedVoice(name: "Alex", samples: [.init(noteID: id, print: print), .init(noteID: otherID, print: print)])])
    try library.savePrints([print], noteID: id)
    try library.removeEvidence(noteID: id)
    let reopened = try VoiceLibrary(root: root)
    #expect(reopened.voices.first?.samples.map(\.noteID) == [otherID])
    #expect(try reopened.prints(noteID: id).isEmpty)
}

@Test func transcriptExportNeverContainsVoiceLinksOrPrivateEvidence() throws {
    var note = Note(title: "Privacy")
    var speaker = NoteSpeaker(id: "speaker", name: "Alex")
    let privateID = UUID(); speaker.match = .confirmed(voice: privateID, score: 0.9); speaker.excludedVoiceIDs = [privateID]
    note.speakers = [speaker]
    note.transcript = [.init(text: "Hello", start: 0, end: 1, speaker: "Alex", speakerID: "speaker")]
    note.saveCurrentVersion(name: "Original")
    let json = String(decoding: try TranscriptFormat.json.data(for: note), as: UTF8.self)
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
    note.saveCurrentVersion(name: "Imported")
    let original = try #require(note.selectedVersionID)
    note.transcript[0].text = "Edited"
    note.saveCurrentVersion(name: "Edited")
    #expect(note.versions?.count == 2)
    note.selectVersion(original)
    #expect(note.text == "Original")
    #expect(note.versions?.last?.segments.first?.text == "Edited")
}

@Test func isolatedSpeechSubtractsOnlyOverlapAndNeverDoubleCounts() {
    let turns: [SpeakerTurn] = [.init(speakerID: "a", start: 0, end: 10), .init(speakerID: "a", start: 5, end: 12), .init(speakerID: "b", start: 3, end: 4), .init(speakerID: "b", start: 8, end: 9)]
    #expect(SpeakerAttribution.isolatedSeconds(speakerID: "a", turns: turns) == 10)
    #expect(SpeakerAttribution.isolatedSeconds(speakerID: "b", turns: turns) == 0)
}

@Test func forgettingEveryoneRemovesAllPrivatePrints() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try VoiceLibrary(root: root)
    let id = UUID(), otherID = UUID()
    let print = SpeakerPrint(speakerID: "a", model: "test", vector: [1, 0], speechSeconds: 8)
    try library.save([SavedVoice(name: "Alex", samples: [.init(noteID: id, print: print)])])
    try library.savePrints([print], noteID: id); try library.savePrints([print], noteID: otherID)
    #expect(library.hasEvidence)
    try library.forgetAll()
    let reopened = try VoiceLibrary(root: root)
    #expect(reopened.voices.isEmpty)
    #expect(!reopened.hasEvidence)
    #expect(try reopened.prints(noteID: otherID).isEmpty)
}
