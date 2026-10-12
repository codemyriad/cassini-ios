import Foundation
import Testing
@testable import CassiniNotebook

/// The private voice files: Android's VoiceRepositoryTest cases about files. The note and generation parts are in
/// CassiniEngineTests (VoiceStoreTests) and the app's hosted tests.
@Suite struct VoiceLibraryTests {
    typealias F = VoiceFixtures
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_234.567)
    var folder: URL { root.appendingPathComponent("PrivateVoices", isDirectory: true) }
    var voicesFile: URL { folder.appendingPathComponent("voices.json") }

    func library() throws -> VoiceLibrary { try VoiceLibrary(root: root, now: { now }) }
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test func voicesAreWrittenInTheVersionOneEnvelopeAndReadBack() throws {
        defer { cleanUp() }
        let voices = [F.voice("anna", "Anna")]
        try library().save(voices)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: voicesFile)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(try library().voices == voices)
        #expect(try library().problem == nil)
    }

    @Test func aLegacyBareArrayReadsAndIsWrittenBackAsVersionOne() throws {
        defer { cleanUp() }
        let voices = [F.voice("anna", "Anna")]
        try write(String(decoding: JSONEncoder().encode(voices), as: UTF8.self), to: voicesFile)
        let library = try library()
        #expect(library.voices == voices)
        try library.save(voices + [F.voice("luca", "Luca")])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: voicesFile)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
    }

    // ports: VoiceRepositoryTest#aNewerPeopleFileStaysReadOnly
    @Test func aNewerVoicesFileStaysReadOnly() throws {
        defer { cleanUp() }
        let newer = #"{"version":2,"voices":[{"id":"x","name":"X"}],"extra":true}"#
        try write(newer, to: voicesFile)
        let library = try library()
        #expect(library.problem == .newer)
        #expect(library.isReadOnly)
        #expect(!library.canForgetEveryone)
        #expect(throws: VoiceLibraryError.readOnly(.newer)) { try library.save([]) }
        #expect(throws: VoiceLibraryError.readOnly(.newer)) { try library.forgetAll() }
        #expect(throws: VoiceLibraryError.readOnly(.newer)) { try library.removeEvidence(noteID: UUID()) }
        #expect(String(decoding: try Data(contentsOf: voicesFile), as: UTF8.self) == newer)
        #expect(library.voices.isEmpty)
    }

    // ports: VoiceRepositoryTest#aNewerNoteFileIsKeptAndNotWritten
    @Test func aNewerNoteFileIsKeptAndNotWritten() throws {
        defer { cleanUp() }
        let note = UUID()
        let newer = #"{"version":3,"prints":[]}"#
        try write(newer, to: file(NoteVoiceCodec.fileName(note)))
        let library = try library()
        #expect(try library.prints(noteID: note).isEmpty)
        #expect(throws: VoiceLibraryError.newerPrints(note)) { try library.savePrints([F.print("s", F.axis(0))], noteID: note) }
        #expect(String(decoding: try Data(contentsOf: file(NoteVoiceCodec.fileName(note))), as: UTF8.self) == newer)
    }

    // ports: VoiceRepositoryTest#unparseableFilesAreRenamedNotDeleted
    @Test func unparseableFilesAreRenamedNotDeleted() throws {
        defer { cleanUp() }
        let note = UUID()
        try write("{not json", to: voicesFile)
        try write("{}", to: file(NoteVoiceCodec.fileName(note)))
        let stamp = Int64((now.timeIntervalSince1970 * 1000).rounded())

        let library = try library()
        #expect(library.problem == .damaged)
        #expect(library.isReadOnly)
        #expect(library.canForgetEveryone)
        #expect(!FileManager.default.fileExists(atPath: voicesFile.path))
        #expect(String(decoding: try Data(contentsOf: file("voices.json.corrupt-\(stamp)")), as: UTF8.self) == "{not json")
        #expect(try library.prints(noteID: note).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file(NoteVoiceCodec.fileName(note) + ".corrupt-\(stamp)").path))

        // A damaged list is read-only: nothing writes a new voices.json over it.
        #expect(throws: VoiceLibraryError.readOnly(.damaged)) { try library.save([F.voice("bea", "Bea")]) }
        #expect(!FileManager.default.fileExists(atPath: voicesFile.path))
        // The problem stays after a relaunch, while the set-aside copy exists.
        #expect(try self.library().problem == .damaged)

        // Forget everyone deletes the copies and starts the list again.
        try library.forgetAll()
        #expect(library.problem == nil)
        #expect(try self.library().problem == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    // ports: VoiceRepositoryTest#anUnreadablePeopleFileIsReadAgainAndAWriteErrorIsAnOutcome
    @Test func anUnreadableVoicesFileIsReadAgainAndAWriteErrorThrows() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            cleanUp()
        }
        try library().save([F.voice("luca", "Luca")])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: voicesFile.path)
        let library = try library()
        #expect(library.problem == .unreadable)
        #expect(throws: VoiceLibraryError.readOnly(.unreadable)) { try library.save([]) }

        // The error passed: the next access reads the file again.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: voicesFile.path)
        #expect(!library.isReadOnly)
        #expect(library.voices.map(\.name) == ["Luca"])
        // An atomic write cannot replace a file in a folder that is read-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try library.save([F.voice("luca", "Luca B.")]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(library.voices.map(\.name) == ["Luca"], "a failed write changes nothing")
        try library.save([F.voice("luca", "Luca B.")])
        #expect(try self.library().voices.map(\.name) == ["Luca B."])
    }

    // ports: VoiceRepositoryTest#forgetEveryoneBumpsTheGenerationAndDeletesEveryPrint
    /// The generation is in the settings on iOS (SettingsStoreTests, the app's hosted tests); here the files.
    @Test func forgetEveryoneDeletesEveryPrintAndSetAsideCopy() throws {
        defer { cleanUp() }
        let library = try library()
        let a = UUID(), b = UUID()
        try library.save([F.voice("luca", "Luca", note: a)])
        try library.savePrints([F.print("s", F.axis(0))], noteID: a)
        try library.savePrints([F.print("s", F.axis(1))], noteID: b)
        try write("{", to: file(NoteVoiceCodec.fileName(b) + ".corrupt-5"))
        try write("keep", to: file("unrelated.txt"))
        #expect(library.hasEvidence)

        try library.forgetAll()

        #expect(library.voices.isEmpty)
        #expect(!library.hasEvidence)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["unrelated.txt"])
        #expect(try self.library().voices.isEmpty)
    }

    // ports: VoiceRepositoryTest#deleteForNoteRemovesBothFilesAndTheLinks
    @Test func removingANotesEvidenceRemovesItsFilesAndSamples() throws {
        defer { cleanUp() }
        let library = try library()
        let gone = UUID(), kept = UUID()
        var luca = F.voice("luca", "Luca", note: kept)
        luca.samples += F.voice("x", note: gone).samples
        try library.save([luca])
        try library.savePrints([F.print("s", F.axis(0))], noteID: gone)
        try write("{", to: file(NoteVoiceCodec.fileName(gone) + ".corrupt-3"))

        try library.removeEvidence(noteID: gone)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["voices.json"])
        #expect(try self.library().voices.first?.samples.map(\.noteID) == [kept])
        try library.removeEvidence(noteID: gone)
    }

    // ports: VoiceRepositoryTest#syncLinksDropsTheFilesOfNotesWithoutARow
    @Test func theSweepDropsThePrintsOfNotesThatAreGone() throws {
        defer { cleanUp() }
        let library = try library()
        let gone = UUID(), kept = UUID()
        try library.savePrints([F.print("s", F.axis(0))], noteID: gone)
        try library.savePrints([F.print("s", F.axis(0)), F.print("t", F.axis(1))], noteID: kept)

        #expect(try library.sweepOrphans(keeping: [kept]) == [gone])

        #expect(!FileManager.default.fileExists(atPath: file(NoteVoiceCodec.fileName(gone)).path))
        #expect(try library.prints(noteID: kept).count == 2)
        #expect(try library.sweepOrphans(keeping: [kept]).isEmpty)
    }
}
