import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// D95 imported catalogue backfill reads only legacy metadata, once; warm loads never reopen word payloads.
struct NoteRepositoryMeetingTimeTests {
    private let start = Date(timeIntervalSince1970: 1_794_214_308.25)

    private func importedNote(time: MeetingTime = .unknown) -> Note {
        var note = Note(title: "English planning meeting", createdAt: start.addingTimeInterval(540), audioFilename: "playback.caf")
        note.origin = .importedDocument
        note.originalAudioFilename = "document.opus"
        note.document = DocumentInfo(state: .ok)
        note.meetingTime = time
        return note
    }

    private func document(start: Date?) throws -> [UInt8] {
        try CassiniDocument.create(PortableFixtures.silence(), transcript: Transcript([Word("a", 0, 100, "Hello")], language: "en"),
                                  title: "English planning meeting", processing: JSONObject(), recordedAt: start)
    }

    private func metadataURL(_ note: Note, _ repository: NoteRepository) -> URL {
        repository.directory(for: note.id).appendingPathComponent(NoteRepository.metadataFilename)
    }

    /// Represents actual pre-D95 metadata: the new root key is absent, not explicitly unknown.
    @discardableResult
    private func writeLegacy(_ note: Note, _ repository: NoteRepository) throws -> Data {
        try repository.save(note)
        let url = metadataURL(note, repository)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "meetingTime")
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: url)
        return bytes
    }

    @Test func legacyImportedStartIsPersistedOnceAndWarmLoadKeepsItWithoutSourceReads() throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let note = importedNote()
        try writeLegacy(note, repository)
        let original = repository.originalAudioURL(for: note)
        let source = try document(start: start)
        try Data(source).write(to: original)
        try Data("Decoded playback is not a portable header".utf8).write(to: repository.audioURL(for: note))

        let first = try #require(try repository.load().notes.first)
        #expect(first.meetingTime == .instant(start))
        let url = metadataURL(note, repository)
        let persisted = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Note.self, from: persisted)
        #expect(decoded.meetingTime == .instant(start))
        let object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(object["meetingTime"] != nil)
        #expect(try Data(contentsOf: original) == Data(source))

        // Preserve a noncanonical but valid encoding to prove a warm load does not write the note again.
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try pretty.write(to: url)
        let replacement = try document(start: start.addingTimeInterval(86_400))
        try Data(replacement).write(to: original)
        #expect(try repository.load().notes.first?.meetingTime == .instant(start), "An explicit cached time is not re-derived on launch")
        #expect(try Data(contentsOf: url) == pretty)
        #expect(try Data(contentsOf: original) == Data(replacement))

        try FileManager.default.removeItem(at: original)
        #expect(try repository.load().notes.first?.meetingTime == .instant(start))
        // The path exists but is temporarily unreadable as a document. Reopening it would erase the known time.
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        #expect(try repository.load().notes.first?.meetingTime == .instant(start))
        #expect(try Data(contentsOf: url) == pretty)
    }

    @Test(arguments: [MeetingTime.unknown, .local("2026-11-08T09:15:00")])
    func explicitImportedValuesAreNeverReplacedBySourceMetadata(_ cached: MeetingTime) throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let note = importedNote(time: cached)
        try repository.save(note)
        let url = metadataURL(note, repository)
        let bytes = try Data(contentsOf: url)
        let source = try document(start: start)
        try Data(source).write(to: repository.originalAudioURL(for: note))
        #expect(try repository.load().notes.first?.meetingTime == cached)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func explicitNullIsPresentRatherThanALegacyMissingKey() throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let note = importedNote()
        try repository.save(note)
        let url = metadataURL(note, repository)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["meetingTime"] = NSNull()
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: url)
        try Data(document(start: start)).write(to: repository.originalAudioURL(for: note))
        #expect(try repository.load().notes.first?.meetingTime == .unknown)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func missingLegacySourceIsRetriedWithoutPersistingAnUnknownFailure() throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let note = importedNote()
        let legacy = try writeLegacy(note, repository)
        let url = metadataURL(note, repository)
        #expect(try repository.load().notes.first?.meetingTime == .unknown)
        #expect(try Data(contentsOf: url) == legacy, "A transient source I/O failure must not finish migration")
        try Data(document(start: start)).write(to: repository.originalAudioURL(for: note))
        #expect(try repository.load().notes.first?.meetingTime == .instant(start))
        #expect(try JSONDecoder().decode(Note.self, from: Data(contentsOf: url)).meetingTime == .instant(start))
    }

    @Test func validMetadataWithNoStartPersistsUnknownOnce() throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let note = importedNote()
        try writeLegacy(note, repository)
        let source = repository.originalAudioURL(for: note)
        try Data(document(start: nil)).write(to: source)
        #expect(try repository.load().notes.first?.meetingTime == .unknown)
        let persisted = try Data(contentsOf: metadataURL(note, repository))
        let object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(object["meetingTime"] != nil)
        try Data(document(start: start)).write(to: source)
        #expect(try repository.load().notes.first?.meetingTime == .unknown)
        #expect(try Data(contentsOf: metadataURL(note, repository)) == persisted)
    }

    @Test(arguments: [DocumentState.invalidMetadata, .unknownFormat, .plainAudio])
    func malformedOrUnsupportedMetadataCannotSupplyAMeetingTime(_ state: DocumentState) throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let note = importedNote()
        let legacy = try writeLegacy(note, repository)
        let valid = try document(start: start)
        let comments = CassiniDocument.read(valid).comments
        let changed: [String]
        switch state {
        case .invalidMetadata: changed = comments.filter { !$0.hasPrefix("CASSINI_PAYLOAD_000=") }
        case .unknownFormat: changed = comments.map { $0.hasPrefix("CASSINI_FORMAT=") ? "CASSINI_FORMAT=org.cassini.portable-meeting/2" : $0 }
        case .plainAudio: changed = comments.filter { !$0.hasPrefix("CASSINI_") }
        default: throw CancellationError()
        }
        let source = try OggOpus.mux(OggOpus.read(valid), tags: CassiniDocument.tagsPacket(changed))
        let original = repository.originalAudioURL(for: note)
        try Data(source).write(to: original)
        try #require(CassiniDocument.readMetadataChecked(original).state == state)
        let report = try repository.load()
        #expect(report.unreadable.isEmpty, "The catalogue remains readable even when its source cannot supply metadata")
        #expect(report.notes.first?.meetingTime == .unknown)
        #expect(try Data(contentsOf: metadataURL(note, repository)) == legacy)
        #expect(try Data(contentsOf: original) == Data(source))
    }
}
