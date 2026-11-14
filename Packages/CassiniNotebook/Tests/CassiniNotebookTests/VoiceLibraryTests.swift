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
        #expect(try library().voices == voices.enumerated().map { $0.element.saved(at: $0.offset) })
        #expect(try library().problem == nil)
    }

    @Test func deletedSlotsAreNotReusedAfterAnEmptyListAndRelaunch() throws {
        defer { cleanUp() }
        let library = try library()
        try library.save([F.voice("alex", "Alex"), F.voice("ben", "Ben")])
        #expect(library.voices.map(\.saveSequence) == [0, 1])
        try library.save(Array(library.voices.prefix(1)))
        try library.save([])
        let reopened = try self.library()
        try reopened.save([F.voice("casey", "Casey")])
        #expect(reopened.voices.first?.saveSequence == 2)
        var renamed = try #require(reopened.voices.first)
        renamed.name = "Zoe"
        renamed.samples.append(VoiceSample(noteID: UUID(), print: F.print(F.axis(1))))
        // A stale or replacement caller cannot change an already-saved person's immutable sequence.
        try reopened.save([F.voice("devon", "Devon"), renamed.saved(at: 900)])
        #expect(reopened.voices.map(\.saveSequence) == [3, 2])
        #expect(try self.library().voices == reopened.voices)
    }

    @Test func legacySaveOrderSurvivesDeletingBeforeItsFirstWrite() throws {
        defer { cleanUp() }
        try write("""
        {"version":1,"voices":[
          {"id":"00000000-0000-0000-0000-000000000001","name":"Zoe","samples":[]},
          {"id":"00000000-0000-0000-0000-000000000002","name":"Alex","samples":[]}
        ]}
        """, to: voicesFile)
        let library = try library()
        #expect(library.voices.map(\.saveSequence) == [0, 1])
        try library.save(Array(library.voices.suffix(1)))
        let reopened = try self.library()
        try reopened.save(reopened.voices + [F.voice("ben", "Ben")])
        #expect(reopened.voices.map(\.saveSequence) == [1, 2])
    }

    @Test func forgettingEveryoneDeletesTheCounterAndRestartsSaveOrder() throws {
        defer { cleanUp() }
        let library = try library()
        try library.save([F.voice("alex", "Alex"), F.voice("ben", "Ben")])
        try library.forgetAll()
        #expect(library.voices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: voicesFile.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // The live instance and a relaunched one both restart after an explicit full wipe.
        try library.save([F.voice("casey", "Casey")])
        #expect(library.voices.first?.saveSequence == 0)
        try library.forgetAll()
        let reopened = try self.library()
        try reopened.save([F.voice("devon", "Devon")])
        #expect(reopened.voices.first?.saveSequence == 0)
    }

    @Test func forgettingThroughASymlinkLeavesNoVoiceEvidenceOrCounter() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
        let library = try VoiceLibrary(root: alias)
        try library.save([F.voice("alex", "Alex")])
        try library.savePrints([F.print(F.axis(0))], noteID: UUID())
        try library.forgetAll()
        #expect(!FileManager.default.fileExists(atPath: voicesFile.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let reopened = try VoiceLibrary(root: root)
        try reopened.save([F.voice("ben", "Ben")])
        #expect(reopened.voices.first?.saveSequence == 0)
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
        #expect(!FileManager.default.fileExists(atPath: voicesFile.path))
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
        // A crash between the write of a print file and its rename leaves the prints in the temporary file.
        try write("{}", to: file(NoteVoiceCodec.fileName(b) + DurableFile.temporarySuffix))
        try write("[]", to: file("voices.json" + DurableFile.temporarySuffix))
        try write("keep", to: file("unrelated.txt"))
        #expect(library.hasEvidence)

        try library.forgetAll()

        #expect(library.voices.isEmpty)
        #expect(!library.hasEvidence)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["unrelated.txt"])
        #expect(!FileManager.default.fileExists(atPath: voicesFile.path))
        #expect(try self.library().voices.isEmpty)
    }

    // ports: VoiceRepositoryTest#deleteForNoteRemovesBothFilesAndTheLinks
    @Test func removingANotesEvidenceRemovesItsFilesAndSamples() throws {
        defer { cleanUp() }
        let library = try library()
        let gone = UUID(), kept = UUID()
        var luca = F.voice("luca", "Luca", note: kept)
        luca.samples += F.voice("x", note: gone).samples
        let anna = F.voice("anna", "Anna", note: gone)
        try library.save([luca, anna])
        try library.savePrints([F.print("s", F.axis(0))], noteID: gone)
        try write("{", to: file(NoteVoiceCodec.fileName(gone) + ".corrupt-3"))
        try write("{}", to: file(NoteVoiceCodec.fileName(gone) + DurableFile.temporarySuffix))

        #expect(try library.removeEvidence(noteID: gone) == [anna.id], "Anna had only samples of the note and is forgotten")

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["voices.json"])
        #expect(try self.library().voices.map(\.id) == [luca.id])
        #expect(try self.library().voices.first?.samples.map(\.noteID) == [kept])
        #expect(try library.removeEvidence(noteID: gone).isEmpty)
    }

    // ports: VoiceRepositoryTest#syncLinksDropsTheFilesOfNotesWithoutARow
    @Test func theSweepDropsThePrintsOfNotesThatAreGone() throws {
        defer { cleanUp() }
        let library = try library()
        let gone = UUID(), kept = UUID()
        try library.savePrints([F.print("s", F.axis(0))], noteID: gone)
        try library.savePrints([F.print("s", F.axis(0)), F.print("t", F.axis(1))], noteID: kept)
        let leftover = file(NoteVoiceCodec.fileName(gone) + DurableFile.temporarySuffix)
        try write("{}", to: leftover)

        #expect(try library.sweepOrphans(keeping: [kept]) == [gone])

        #expect(!FileManager.default.fileExists(atPath: file(NoteVoiceCodec.fileName(gone)).path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try library.prints(noteID: kept).count == 2)
        #expect(try library.sweepOrphans(keeping: [kept]).isEmpty)
    }

    /// A note whose `note.json` could not be read is not in the list, but its folder is kept, and so are its prints.
    @Test func theSweepKeepsThePrintsOfNoteFoldersThatCouldNotBeRead() throws {
        defer { cleanUp() }
        let library = try library()
        let unreadable = UUID()
        try write(#"{"schemaVersion":3}"#, to: root.appendingPathComponent(unreadable.uuidString).appendingPathComponent("note.json"))
        try library.savePrints([F.print("s", F.axis(0))], noteID: unreadable)

        #expect(try library.sweepOrphans(keeping: []).isEmpty)

        #expect(try library.prints(noteID: unreadable).count == 1)
    }
}
