import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct NoteSchemaTests {
    private func decode(_ json: String) throws -> Note { try JSONDecoder().decode(Note.self, from: Data(json.utf8)) }

    private let id = UUID()
    private let voice = UUID()

    @Test func aSchemaOneNoteMapsEveryOldFieldToItsSchemaTwoField() throws {
        let note = try decode(#"""
        {"schemaVersion":1,"id":"\#(id)","title":"Old","createdAt":10,"audioFilename":"playback.caf","duration":3,
         "status":"failed","language":"en_US","failureMessage":"This recording was interrupted before its audio file was finalized.",
         "playbackUnavailable":"This device cannot play the imported Opus container.","originalAudioFilename":"audio.opus",
         "speakerAnalysisMessage":"No speakers were detected. You can assign passages manually.",
         "speakers":[{"id":"a","name":"Alex","voiceID":"\#(voice)","suggestedVoiceID":"\#(voice)","excludedVoiceIDs":[]},
                     {"id":"b","name":"Sam","voiceID":"\#(voice)"},
                     {"id":"c","name":"Kim","suggestedVoiceID":"\#(voice)"},
                     {"id":"d","name":"Lee"}]}
        """#)
        #expect(note.language == "en-US")
        #expect(note.failure == .audio)
        #expect(note.audio == .unplayable(.unsupportedFormat))
        #expect(note.origin == .imported)
        #expect(note.speakerAnalysisFailure == .empty)
        #expect(note.speakers?.map(\.match) == [.auto(voice: voice, score: 0), .confirmed(voice: voice, score: 0),
                                                 .suggested(voice: voice, score: 0), .unmatched])
    }

    @Test func aSchemaOneRecordingIsLiveAndItsDefaultsAreFilledIn() throws {
        let note = try decode(#"{"id":"\#(id)","title":"Capture","createdAt":0,"audioFilename":"capture.caf","status":"recording"}"#)
        #expect(note.audio == .live)
        #expect(note.isRecording)
        #expect(note.origin == .recorded)
        #expect(note.language == "")
        #expect(note.failure == nil && note.transcript.isEmpty && note.bookmarks.isEmpty)
    }

    @Test func aSchemaOneImportedDocumentKeepsItsOrigin() throws {
        let note = try decode(#"""
        {"schemaVersion":1,"id":"\#(id)","title":"Doc","createdAt":0,"audioFilename":"audio.opus","status":"ready",
         "versions":[{"id":"\#(UUID())","name":"Imported","portableID":"v1","createdAt":0,"segments":[],"speakers":[]}]}
        """#)
        #expect(note.origin == .importedDocument)
    }

    @Test func schemaTwoRoundTripsEveryField() throws {
        var note = Note(id: id, title: "Full", createdAt: Date(timeIntervalSince1970: 100), audioFilename: "audio.m4a")
        note.language = "it-IT"; note.audio = .unplayable(.interrupted); note.origin = .recovered
        note.document = DocumentInfo(state: .staleAudio, warnings: ["w"], unavailableVariants: ["v2": "broken"], trustAcknowledged: true, vendor: "cassini-android")
        note.sourceSha256 = "abc"; note.trashedJob = TrashedJob(state: .queued, kind: .transcribeAgain)
        note.previewText = "Preview…"; note.failure = .download(.notEnoughStorage); note.speakerAnalysisFailure = .speakers
        note.speakers = [NoteSpeaker(id: "a", name: "Alex", match: .rejected(voice: voice, score: 0.7))]
        let data = try JSONEncoder().encode(note)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["failure"] as? String == "DOWNLOAD_NOT_ENOUGH_STORAGE")
        #expect(try JSONDecoder().decode(Note.self, from: data) == note)
    }

    @Test func aNewerSchemaIsRefused() {
        #expect(throws: NoteDecodingError.unsupportedSchema(3)) {
            try decode(#"{"schemaVersion":3,"id":"\#(id)","title":"Future","createdAt":0,"audioFilename":"a.m4a","audio":{"plain":{}},"origin":"recorded"}"#)
        }
    }

    @Test func anUnknownFailureCodeReadsAsUnknown() throws {
        let note = try decode(#"{"schemaVersion":2,"id":"\#(id)","title":"T","createdAt":0,"audioFilename":"a.m4a","audio":{"plain":{}},"origin":"recorded","failure":"SOMETHING_NEW"}"#)
        #expect(note.failure == .unknown)
    }
}
