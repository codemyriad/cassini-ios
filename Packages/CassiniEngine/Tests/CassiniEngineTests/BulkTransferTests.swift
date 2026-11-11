import CassiniCore
import CassiniNotebook
import CassiniEngineTesting
import Foundation
import Synchronization
import Testing
@testable import CassiniEngine

struct BulkTransferTests {
    private let root: URL
    private let notes: NoteStore
    private let storage = FakeStorage()
    private let audio = FakeAudioProcessing(duration: 1)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-transfer-\(UUID())", isDirectory: true)
        notes = try NoteStore(root: root.appendingPathComponent("Notes", isDirectory: true))
    }

    private var importer: ImportService {
        ImportService(notes: notes, files: CoordinatedFileImporter(storage: storage), audio: audio,
                      storage: storage, clock: FakeClock())
    }

    private func input(_ data: Data, _ name: String) throws -> URL {
        let folder = root.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func englishDocument() throws -> Data {
        try Data(CassiniDocument.create(ImportFixtures.opus(packets: 50),
            transcript: Transcript([Word("a", 0, 200, "Hello"), Word("a", 200, 400, "English"), Word("a", 400, 600, "meeting")], language: "en"),
            title: "English planning", processing: JSONObject(), speakerLabels: ["a": "Alex"]))
    }

    @Test func selectionImportsDocumentsAndAudioDeduplicatesAndCountsIgnoredFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try input(englishDocument(), "English.opus")
        let wave = try input(Data(ImportFixtures.wav), "Sample.wav")
        let text = try input(Data("English readme".utf8), "Readme.txt")
        let nested = try input(Data([1, 2, 3]), "Nested.zip")
        let zip = root.appendingPathComponent("Selection.zip")
        try ZipArchive.write([ZipSource(url: document, name: "Meeting.opus"), ZipSource(url: document, name: "Again.opus"),
                              ZipSource(url: wave, name: "Sample.wav"), ZipSource(url: text, name: "Readme.txt"),
                              ZipSource(url: nested, name: "Nested.zip")], to: zip)
        let summary = try await importer.importBatch([zip, wave], fallbackTitle: "Imported audio")
        #expect(summary.imported == 2)
        #expect(summary.duplicates == 2)
        #expect(summary.unsupported == 2)
        #expect(summary.failed == 0)
        #expect(summary.archiveFailures.isEmpty)
        #expect(await notes.all().count == 2)
        let portable = try #require(await notes.all().first { $0.origin == .importedDocument })
        #expect(portable.title == "English planning")
        #expect(portable.language == "en")
        #expect(portable.text == "Hello English meeting")
        #expect(try Data(contentsOf: notes.originalAudioURL(for: portable)) == Data(contentsOf: document))
        #expect(stagingIsEmpty)
    }

    @Test func archiveNamesLongerThanNameMaxNeverBecomeFilesystemNames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = try input(Data(ImportFixtures.wav), "source.wav")
        let zip = root.appendingPathComponent("Long names.zip")
        let title = String(repeating: "界", count: 200)
        try ZipArchive.write([ZipSource(url: wave, name: title + ".wav")], to: zip)
        let summary = try await importer.importBatch([zip], fallbackTitle: "Imported audio")
        #expect(summary.imported == 1)
        #expect(summary.failed == 0)
        let note = try #require(await notes.all().first)
        #expect(note.title.hasPrefix(String(repeating: "界", count: 50)))
        #expect(note.audioFilename == "source.wav")
        #expect(try Data(contentsOf: notes.audioURL(for: note)) == Data(ImportFixtures.wav))
    }

    @Test func unknownContainerSignaturesUseThePlatformProbeRatherThanDiscardingSupportedAudio() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("English synthetic platform audio".utf8)
        let source = try input(bytes, "platform.audio")
        let zip = root.appendingPathComponent("Platform.zip")
        try ZipArchive.write([ZipSource(url: source, name: "Recording.audio")], to: zip)
        let platformProbe = FakeAudioProcessing(duration: 1, opensAnyFile: true)
        let platformImporter = ImportService(notes: notes, files: CoordinatedFileImporter(storage: storage),
            audio: platformProbe, storage: storage, clock: FakeClock())
        let summary = try await platformImporter.importBatch([zip], fallbackTitle: "Imported audio")
        #expect(summary.imported == 1)
        #expect(summary.unsupported == 0)
        let note = try #require(await notes.all().first)
        #expect(try Data(contentsOf: notes.originalAudioURL(for: note)) == bytes)
    }

    @Test func corruptionInALaterEntryDoesNotImportEarlierValidEntries() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try input(Data(ImportFixtures.wav), "first.wav")
        let second = try input(Data(ImportFixtures.mp3), "second.mp3")
        let zip = root.appendingPathComponent("Corrupt.zip")
        try ZipArchive.write([ZipSource(url: first, name: "First.wav"), ZipSource(url: second, name: "Second.mp3")], to: zip)
        var bytes = try Data(contentsOf: zip)
        let payload = try #require(bytes.range(of: Data(ImportFixtures.mp3)))
        bytes[payload.lowerBound] ^= 1
        try bytes.write(to: zip)
        let summary = try await importer.importBatch([zip], fallbackTitle: "Imported audio")
        #expect(summary.archiveFailures == [.damaged])
        #expect(summary.imported == 0)
        #expect(await notes.all().isEmpty)
        #expect(stagingIsEmpty)
    }

    @Test func anOversizedEntryFailsIndividuallyWithoutRejectingOtherAudio() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let large = try input(Data(ImportFixtures.wav), "Large.wav")
        let small = try input(Data(ImportFixtures.mp3.prefix(64)), "Small.mp3")
        let zip = root.appendingPathComponent("Entry limit.zip")
        try ZipArchive.write([ZipSource(url: large, name: "Large.wav"), ZipSource(url: small, name: "Small.mp3")], to: zip)
        let service = BulkImportService(importer: importer, files: CoordinatedFileImporter(storage: storage), storage: storage,
            folder: root.appendingPathComponent("Notes/.bulk-imports"), maxEntryBytes: 100)
        let summary = try await service.importFiles([zip], fallbackTitle: "Imported audio")
        #expect(summary.imported == 1)
        #expect(summary.failed == 1)
        #expect(summary.outcomes.contains(.rejected(.tooLarge)))
        #expect(summary.archiveFailures.isEmpty)
        #expect(await notes.all().count == 1)
    }

    @Test func extractionPreservesTheFreeSpaceReserveAndReportsStorageRatherThanDamagedZip() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = try input(Data(ImportFixtures.wav), "Source.wav")
        let zip = root.appendingPathComponent("Space.zip")
        try ZipArchive.write([ZipSource(url: wave, name: "Source.wav")], to: zip)
        let files = SpaceDropsAfterCopy(base: CoordinatedFileImporter(storage: storage), storage: storage)
        let service = BulkImportService(importer: importer, files: files, storage: storage,
            folder: root.appendingPathComponent("Notes/.bulk-imports"))
        let summary = try await service.importFiles([zip], fallbackTitle: "Imported audio")
        #expect(summary.imported == 0)
        #expect(summary.failed == 1)
        #expect(summary.archiveFailures.isEmpty)
        #expect(summary.outcomes == [.rejected(.noSpace(bytesNeeded: Limits.minFreeImportBytes + Int64(ImportFixtures.wav.count)))])
        #expect(await notes.all().isEmpty)
        #expect(stagingIsEmpty)
    }

    @Test func finishingABatchNeverRemovesAnotherBatchsStagingDirectory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes/.bulk-imports")
        let sibling = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let marker = sibling.appendingPathComponent("active")
        try Data("another English import".utf8).write(to: marker)
        let service = BulkImportService(importer: importer, files: CoordinatedFileImporter(storage: storage), storage: storage, folder: folder)
        _ = try await service.importFiles([], fallbackTitle: "Imported audio")
        #expect(try Data(contentsOf: marker) == Data("another English import".utf8))
    }

    @Test func cancellationAfterAnOutcomeRetainsThatNoteAndRemovesStaging() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = try input(Data(ImportFixtures.wav), "first.wav")
        let mp3 = try input(Data(ImportFixtures.mp3), "second.mp3")
        let zip = root.appendingPathComponent("Cancel.zip")
        try ZipArchive.write([ZipSource(url: wave, name: "First.wav"), ZipSource(url: mp3, name: "Second.mp3")], to: zip)
        let arrived = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { arrived.continuation.finish(); release.continuation.finish() }
        let service = importer
        let task = Task {
            try await service.importBatch([zip], fallbackTitle: "Imported audio") { event in
                if case .outcome(.created) = event {
                    arrived.continuation.yield(())
                    for await _ in release.stream { break }
                }
            }
        }
        for await _ in arrived.stream { break }
        task.cancel()
        release.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await notes.all().count == 1)
        #expect(stagingIsEmpty)
    }

    @Test func exportStoresCompleteDocumentsAndOriginalAudioWithCollisionSuffixes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let originalDocument = try englishDocument()
        let source = try input(originalDocument, "English.opus")
        let imported = try await importer.importFile(source, fallbackTitle: "Imported audio")
        let documentID = try #require(imported.noteID)
        try await notes.mutate(documentID) { $0.title = "Same title" }
        let rawSource = try input(Data(ImportFixtures.wav), "Original.wav")
        let rawID = try #require(try await importer.importFile(rawSource, fallbackTitle: "Imported audio").noteID)
        try await notes.mutate(rawID) { $0.title = "Same title" }
        let raw2 = try input(Data(ImportFixtures.mp3), "Original.mp3")
        let raw2ID = try #require(try await importer.importFile(raw2, fallbackTitle: "Imported audio").noteID)
        try await notes.mutate(raw2ID) { $0.title = "Same title"; $0.status = .ready }
        // A second distinct WAV tests same-extension collision as well as duplicate selection identity.
        let altered = try input(Data(ImportFixtures.wav + [9]), "Another.wav")
        let raw3ID = try #require(try await importer.importFile(altered, fallbackTitle: "Imported audio").noteID)
        try await notes.mutate(raw3ID) { $0.title = "same TITLE" }
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        let portable = PortableExportService(audio: audio, provenance: ProvenanceFiles(notes: notes), unassignedLabel: "Unknown speaker")
        let service = BulkExportService(notes: notes, portable: portable, folder: exports)
        let zip = try await service.export([documentID, rawID, raw2ID, raw3ID, rawID])
        let archive = try ZipArchive(url: zip)
        #expect(archive.entries.map(\.baseName) == ["Same title.opus", "Same title.wav", "Same title.mp3", "same TITLE (2).wav"])
        #expect(archive.entries.allSatisfy { $0.compressedSize == $0.uncompressedSize })
        for entry in archive.entries {
            let output = root.appendingPathComponent(UUID().uuidString)
            _ = try archive.extract(entry, to: output, maxBytes: Limits.maxImportBytes)
            if entry.baseName.hasSuffix(".opus") {
                let doc = CassiniDocument.read(output)
                #expect(doc.state == .ok)
                #expect(doc.selected()?.transcript?.words.map(\.text) == ["Hello", "English", "meeting"])
                #expect(doc.title == "Same title")
            } else if entry.baseName == "Same title.wav" { #expect(try Data(contentsOf: output) == Data(ImportFixtures.wav)) }
            else if entry.baseName == "same TITLE (2).wav" { #expect(try Data(contentsOf: output) == Data(ImportFixtures.wav + [9])) }
            else { #expect(try Data(contentsOf: output) == Data(ImportFixtures.mp3)) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: zip.deletingLastPathComponent().path) == ["Cassini.zip"])
        ExportService(notes: notes, folder: exports).discard(zip)
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(try Data(contentsOf: source) == originalDocument)
    }

    @Test func exportCancellationRemovesEveryIntermediateAndKeepsSourceAudio() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try input(Data(ImportFixtures.wav), "Original.wav")
        let id = try #require(try await importer.importFile(source, fallbackTitle: "Imported audio").noteID)
        let folder = root.appendingPathComponent("Exports")
        let service = BulkExportService(notes: notes,
            portable: PortableExportService(audio: audio, provenance: ProvenanceFiles(notes: notes), unassignedLabel: "Unknown speaker"), folder: folder)
        let prepared = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { prepared.continuation.finish(); release.continuation.finish() }
        let task = Task {
            try await service.export([id]) { done, _ in
                if done == 1 {
                    prepared.continuation.yield(())
                    for await _ in release.stream { break }
                }
            }
        }
        for await _ in prepared.stream { break }
        task.cancel()
        release.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try Data(contentsOf: source) == Data(ImportFixtures.wav))
    }

    private var stagingIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes/.bulk-imports").path)) ?? []).isEmpty
    }
}

private struct SpaceDropsAfterCopy: FileImporting {
    let base: any FileImporting
    let storage: FakeStorage
    func copy(from source: URL, to destination: URL, maxBytes: Int64, reserveBytes: Int64) async throws -> ImportedFile {
        let copied = try await base.copy(from: source, to: destination, maxBytes: maxBytes, reserveBytes: reserveBytes)
        storage.set(availableBytes: Limits.minFreeImportBytes)
        return copied
    }
}
