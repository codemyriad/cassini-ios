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
    #expect(imported.speakers.map(\.id) == ["spk_1", "spk_2"])
    var note = Note(title: "Renamed portable note")
    note.transcript = imported.segments; note.speakers = imported.speakers
    note.renameSpeaker("spk_1", name: "Alice")
    note.transcript[1].text = "Edited reply"; note.transcript[1].words = []
    let output = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".opus")
    defer { try? FileManager.default.removeItem(at: output) }
    try PortableTranscript.export(note: note, opus: url, destination: output)
    let document = CassiniDocument.read(output)
    #expect(document.state == .ok)
    #expect(document.title == note.title)
    #expect(document.variants.count == 2)
    #expect(document.variants.first?.transcript == transcript)
    #expect(document.speakerLabel("spk_1") == "Alice")
    #expect(document.selected()?.transcript?.words.map(\.text) == ["Hello", "Edited", "reply"])
    #expect(try OggOpus.scan(output).digest() == OggOpus.scan(url).digest())
    #expect(try Data(contentsOf: url) == original)
    #expect(PortableTranscript.read(from: output)?.versions.count == 2)
    try Data(audio).write(to: url)
    #expect(PortableTranscript.read(from: url) == nil)
    try Data("invalid".utf8).write(to: url)
    #expect(PortableTranscript.read(from: url) == nil)
}
