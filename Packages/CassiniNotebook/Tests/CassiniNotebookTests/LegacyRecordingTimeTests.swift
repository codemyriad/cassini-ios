import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Pre-D95 producer/encoder shapes, captured as literal JSON rather than deleting fields from today's encoder.
/// Schema 2: RecordingController.begin at 94239b6 creates the recorded origin and recorder start stamp;
/// finish changes duration/audio filename but leaves createdAt alone. Schema 1: AppStore.startRecording at
/// b95d416^ uses capture.caf, while its importer also used audio.m4a, so the latter cannot prove recorder origin.
struct LegacyRecordingTimeTests {
    private let id = UUID(uuidString: "22222222-1111-4444-8888-111111111111")!
    private let stamp = Date(timeIntervalSinceReferenceDate: 815_909_508)

    private func legacy(schema: Int, filename: String, origin: String = "recorded", extra: String = "") -> Data {
        let modern = schema == 2 ? #", "audio":{"plain":{}},"origin":"\#(origin)""# : ""
        return Data(#"""
        {"schemaVersion":\#(schema),"id":"22222222-1111-4444-8888-111111111111",
         "title":"Legacy English planning meeting","createdAt":815909508,"audioFilename":"\#(filename)",
         "duration":1,"status":"ready","language":"en-US","bookmarks":[],"waveform":[],
         "isFavorite":false,"playbackPosition":0,
         "transcript":[{"id":"33333333-1111-4444-8888-111111111111","text":"Hello",
                        "start":0,"end":0.02,"words":[]}]\#(modern)\#(extra)}
        """#.utf8)
    }

    @Test(arguments: [1, 2])
    func preD95RecorderJsonReloadsAndExportsItsSavedStart(_ schema: Int) throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let folder = repository.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = legacy(schema: schema, filename: schema == 1 ? "capture.caf" : "audio.m4a")
        let metadata = folder.appendingPathComponent(NoteRepository.metadataFilename)
        try json.write(to: metadata)
        let note = try #require(repository.load().notes.first)
        #expect(note.origin == .recorded)
        #expect(note.createdAt == stamp)
        #expect(note.meetingTime == .instant(stamp))
        #expect(try Data(contentsOf: metadata) == json, "Loading upgrades the in-memory projection, not user metadata")
        // The real export service first encodes the recorder CAF/M4A to Opus. This pure fixture starts at that boundary.
        let encoded = root.appendingPathComponent("encoded.opus")
        let audio = Data(try PortableFixtures.silence())
        try audio.write(to: encoded)
        let exported = root.appendingPathComponent("exported.opus")
        try PortableTranscript.export(note: note, opus: encoded, destination: exported, unassignedLabel: "Unknown speaker")
        let document = CassiniDocument.readChecked(exported)
        #expect(document.state == .ok)
        #expect(document.manifest?["meeting"]?.object?["recordedAtUtc"]?.string == "2026-11-09T09:31:48.000Z")
        #expect(document.comments.contains("CASSINI_RECORDED_AT_UTC=2026-11-09T09:31:48.000Z"))
        #expect(document.comments.contains("DATE=2026-11-09T09:31:48.000Z"))
        #expect(try #require(PortableTranscript.read(from: exported)).meetingTime == .instant(stamp))
        #expect(try Data(contentsOf: encoded) == audio)
        #expect(try Data(contentsOf: metadata) == json)
        // A normal later write persists the recovered distinction explicitly and the next load retains it.
        try repository.save(note)
        #expect(try repository.load().notes.first?.meetingTime == .instant(stamp))
    }

    @Test(arguments: ["imported", "importedDocument", "recovered"])
    func preD95ImportSealAndFilesystemStampsNeverBecomeRecorderStarts(_ origin: String) throws {
        let root = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let folder = repository.directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try legacy(schema: 2, filename: "audio.m4a", origin: origin)
            .write(to: folder.appendingPathComponent(NoteRepository.metadataFilename))
        let note = try #require(repository.load().notes.first)
        #expect(note.meetingTime == .unknown)
        #expect(note.createdAt == stamp)
        let encoded = root.appendingPathComponent("encoded.opus")
        try Data(PortableFixtures.silence()).write(to: encoded)
        let exported = root.appendingPathComponent("exported.opus")
        try PortableTranscript.export(note: note, opus: encoded, destination: exported, unassignedLabel: "Unknown speaker")
        let document = CassiniDocument.readChecked(exported)
        #expect(document.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
        #expect(document.comments.allSatisfy { !$0.hasPrefix("CASSINI_RECORDED_AT_UTC=") })
        #expect(try #require(PortableTranscript.read(from: exported)).meetingTime == .unknown)
    }

    @Test func ambiguousSchemaOneM4aAndExplicitUnknownOrImportEvidenceStayUnknown() throws {
        let ambiguous = try JSONDecoder().decode(Note.self, from: legacy(schema: 1, filename: "audio.m4a"))
        #expect(ambiguous.origin == .recorded, "The old origin heuristic alone cannot distinguish this filename")
        #expect(ambiguous.meetingTime == .unknown)
        for extra in [#", "meetingTime":{"unknown":{}}"#, #", "meetingTime":null"#,
                      #", "sourceSha256":"imported-audio-digest""#, #", "originalAudioFilename":"source.m4a""#] {
            let note = try JSONDecoder().decode(Note.self, from: legacy(schema: 2, filename: "audio.m4a", extra: extra))
            #expect(note.meetingTime == .unknown)
        }
    }
}
