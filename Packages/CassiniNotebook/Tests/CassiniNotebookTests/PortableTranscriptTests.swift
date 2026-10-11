import Foundation
import Testing
import CassiniCore
@testable import CassiniNotebook

@Test func portableImportPreservesVerifiedWordsAndOriginal() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
    defer { try? FileManager.default.removeItem(at: url) }
    let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
    let tags = CassiniDocument.tagsPacket(["X_CUSTOM=keep=me"])
    let audio = try OggOpus.mux(OggOpus.Stream(head: head, tags: tags, audio: [[0xF8, 0xFF, 0xFE]], finalGranule: 960, validFraming: true), tags: tags)
    let transcript = Transcript([Word("spk_1", 0, 15, "Hello"), Word("spk_2", 5, 20, "there.")], language: "en")
    let original = Data(try CassiniDocument.create(audio, transcript: transcript, title: "Portable note", processing: JSONObject(), speakerLabels: ["spk_1": "Alex", "spk_2": "Sam"]))
    try original.write(to: url)
    let imported = try #require(PortableTranscript.read(from: url))
    #expect(imported.title == "Portable note")
    #expect(imported.language == "en")
    #expect(imported.segments.map(\.text) == ["Hello", "there."])
    #expect(imported.segments.map(\.speaker) == ["Alex", "Sam"])
    #expect(imported.segments.map(\.start) == [0, 0.005])
    #expect(try Data(contentsOf: url) == original)
    try Data(audio).write(to: url)
    #expect(PortableTranscript.read(from: url) == nil)
    try Data("invalid".utf8).write(to: url)
    #expect(PortableTranscript.read(from: url) == nil)
}
