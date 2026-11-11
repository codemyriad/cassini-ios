@testable import CassiniEngine
import CassiniCore
import CassiniNotebook
import CassiniEngineTesting
import Foundation
import Testing

private final class BulkSandbox: Sendable {
    let folder = URL.temporaryDirectory.appendingPathComponent("bulk-test-" + UUID().uuidString)
    let notes: NoteStore
    let audio = FakeAudioProcessing()
    let storage = FakeStorage()
    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notes = try NoteStore(root: folder.appendingPathComponent("notes"))
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
    var scratch: URL { folder.appendingPathComponent("scratch") }
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name); try data.write(to: url); return url
    }
    func archive(_ members: [(String, Data)]) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString + ".zip")
        let writer = try StoredZIPWriter(url: url)
        for (i, member) in members.enumerated() {
            let source = try file("input-\(i)", member.1)
            try writer.add(file: source, name: member.0)
        }
        try writer.finish(); return url
    }
    func service(limits: ZIPLimits = .init(), memberLimit: UInt64 = UInt64(Limits.maxImportBytes)) -> BulkImportService {
        let importer = ImportService(notes: notes, files: CoordinatedFileImporter(storage: storage), audio: audio,
                                     storage: storage, clock: FakeClock())
        return BulkImportService(files: CoordinatedFileImporter(storage: storage), scratch: scratch, limits: limits, memberLimit: memberLimit) { url, name in
            try await importer.importFile(url, fallbackTitle: "Imported audio", displayName: name)
        }
    }
    func scratchContents() throws -> [String] {
        FileManager.default.fileExists(atPath: scratch.path) ? try FileManager.default.contentsOfDirectory(atPath: scratch.path) : []
    }
}

private final class BulkEvent: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func signal() { continuation.yield(()); continuation.finish() }
    func wait() async { for await _ in stream { return } }
}

private actor BulkProgressTrace {
    var values: [TransferProgress] = []
    func append(_ value: TransferProgress) { values.append(value) }
}

@Suite(.timeLimit(.minutes(1))) struct BulkTransferTests {
    @Test func archiveUsesRealDigestDedupAndCountsIgnoredMembers() async throws {
        let sandbox = try BulkSandbox()
        let bytes = Data(ImportFixtures.wav)
        let zip = try sandbox.archive([("English meeting.wav", bytes), ("Same audio.wav", bytes),
                                       ("README.txt", Data("English fixture".utf8)), ("nested.zip", Data())])
        let report = await sandbox.service().run([zip])
        #expect(report.summary.imported == 1)
        #expect(report.summary.duplicates == 1)
        #expect(report.summary.unsupported == 2)
        #expect(report.summary.failed == 0)
        #expect(report.archives.isEmpty)
        let notes = await sandbox.notes.all()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "English meeting")
        #expect(try sandbox.scratchContents().isEmpty)
    }

    @Test func finderMetadataCountsUnsupportedWithoutOpeningItsAudioLookingMembers() async throws {
        let sandbox = try BulkSandbox()
        let zip = try sandbox.archive([("English.wav", Data(ImportFixtures.wav)),
                                       ("MMMMMMMMM._English.wav", Data("AppleDouble".utf8)),
                                       ("._English.wav", Data("AppleDouble".utf8)),
                                       ("MMMMMMMMMAnother.wav", Data("Metadata".utf8))])
        var bytes = try Data(contentsOf: zip)
        while let range = bytes.range(of: Data("MMMMMMMMM".utf8)) { bytes.replaceSubrange(range, with: Data("__MACOSX/".utf8)) }
        try bytes.write(to: zip)
        let report = await sandbox.service().run([zip])
        #expect(report.summary.imported == 1)
        #expect(report.summary.unsupported == 3)
        #expect(report.summary.failed == 0)
        #expect(report.archives.isEmpty)
        #expect(try sandbox.scratchContents().isEmpty)
    }

    @Test func exportWritesEachMemberAndDeletesItsSnapshotBeforePreparingTheNext() async throws {
        let sandbox = try BulkSandbox()
        let first = Note(title: "English first"), second = Note(title: "English second")
        let bytes = Data(repeating: 7, count: 2 * ZIPArchive.chunkBytes)
        let source = try sandbox.file("original.wav", bytes)
        let exports = sandbox.folder.appendingPathComponent("exports")
        let service = BulkExportService(folder: exports) { note, work in
            let parent = work.deletingLastPathComponent()
            let contents = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            #expect(Set(contents) == Set(["Cassini.zip", work.lastPathComponent]), "Only the current note may be staged")
            if note.id == second.id {
                let size = try FileManager.default.attributesOfItem(atPath: parent.appendingPathComponent("Cassini.zip").path)[.size] as? NSNumber
                #expect((size?.intValue ?? 0) > bytes.count, "The first member must already be in the destination ZIP")
            }
            return try await BulkExportService.copyOriginal(source, to: work.appendingPathComponent("original.wav"))
        }
        let output = try await service.export([first, second])
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path) == ["Cassini.zip"])
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func runtimeBombsRefuseArchiveAndNeverImportTheFollowingGoodMember() async throws {
        for padded in [false, true] {
            let sandbox = try BulkSandbox()
            let zip = sandbox.folder.appendingPathComponent("bomb.zip")
            try ZIPAgyFixture.write([ZIPAgyFixture.bomb(padded: padded, forgedSize: !padded), .init("Good.wav", Data(ImportFixtures.wav))], to: zip)
            let report = await sandbox.service().run([zip])
            #expect(report.archives == [.tooLarge])
            #expect(report.summary.imported == 0)
            #expect(report.summary.failed == 0)
            #expect(await sandbox.notes.all().isEmpty)
            #expect(try sandbox.scratchContents().isEmpty)
        }
    }
    @Test func directoriesDoNotCountAsUnsupportedAndArchiveErrorsAreNotFailedFiles() async throws {
        let sandbox = try BulkSandbox()
        let zip = sandbox.folder.appendingPathComponent("Finder.zip")
        try ZIPAgyFixture.write([.init("Meetings/", Data()), .init("__MACOSX/", Data()),
                                .init("__MACOSX/._English.wav", Data("AppleDouble".utf8)),
                                .init("Meetings/English.wav", Data(ImportFixtures.wav))], to: zip)
        let report = await sandbox.service().run([zip])
        #expect(report.summary.imported == 1)
        #expect(report.summary.unsupported == 1)
        #expect(report.summary.failed == 0)
        try ZIPAgyFixture.write([.init("__MACOSX/", Data()), .init("__MACOSX/._English.wav", Data("AppleDouble".utf8))], to: zip)
        let metadataOnly = await sandbox.service().run([zip])
        #expect(metadataOnly.archives == [.empty])
        #expect(metadataOnly.summary.unsupported == 1)
        #expect(metadataOnly.summary.failed == 0)
        let empty = try sandbox.archive([])
        let failures = await sandbox.service().run([empty, empty])
        #expect(failures.archives == [.empty])
        #expect(failures.archiveFailures == [.empty])
        #expect(failures.summary.failed == 0)
        var model = BulkImportReport(); model.archives = [.empty, .damaged, .empty]
        #expect(model.archiveFailures == [.empty, .damaged])
    }
    @Test func storageFullIsPreservedAndStopsTheBatch() async throws {
        let sandbox = try BulkSandbox()
        let zip = try sandbox.archive([("English.wav", Data(ImportFixtures.wav))])
        sandbox.storage.set(availableBytes: 0)
        let report = await sandbox.service().run([zip, zip])
        guard case .noSpace = report.storageFailure else { Issue.record("Storage-full must retain its specific notice"); return }
        #expect(report.summary.failed == 1)
        #expect(try sandbox.scratchContents().isEmpty)
        #expect(await sandbox.notes.all().isEmpty)
        sandbox.storage.set(availableBytes: 64 << 30)
        let memberStorageFailure = BulkImportService(files: CoordinatedFileImporter(storage: sandbox.storage), scratch: sandbox.scratch) { _, _ in
            .rejected(.noSpace(bytesNeeded: 111))
        }
        let memberReport = await memberStorageFailure.run([zip, zip])
        #expect(memberReport.storageFailure == .noSpace(bytesNeeded: 111))
        #expect(memberReport.summary.failed == 1)
        #expect(try sandbox.scratchContents().isEmpty)
    }
    @Test func exportSelectionOmitsLiveAndTrashedNotesButKeepsOpaqueStoredDocuments() {
        let normal = Note(title: "English finished")
        var live = Note(title: "English recording"); live.audio = .live
        var trashed = Note(title: "English trashed"); trashed.trashedAt = Date()
        var opaque = Note(title: "English future document"); opaque.audio = .unplayable(.unsupportedFormat)
        #expect(ArchiveSelection.ids([normal, live, trashed, opaque]) == [normal.id, opaque.id])
        #expect(ArchiveSelection.ids([live]).isEmpty)
    }

    @Test func unsafeLaterMemberRefusesWholeArchiveBeforeFirstImport() async throws {
        let sandbox = try BulkSandbox()
        let zip = try sandbox.archive([("First.wav", Data(ImportFixtures.wav)), ("aa_notes.wav", Data(ImportFixtures.wav))])
        var data = try Data(contentsOf: zip)
        let safe = Data("aa_notes.wav".utf8), unsafe = Data("../notes.wav".utf8)
        var offset = 0
        while let range = data.range(of: safe, in: offset..<data.count) {
            data.replaceSubrange(range, with: unsafe); offset = range.upperBound
        }
        try data.write(to: zip)
        let report = await sandbox.service().run([zip])
        #expect(report.archives == [.unsafePaths])
        #expect(report.summary.imported == 0)
        #expect(await sandbox.notes.all().isEmpty)
        #expect(try sandbox.scratchContents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder.appendingPathComponent("notes.wav").path))
    }

    @Test func cancelAfterAnImportedMemberKeepsItAndRemovesAllStaging() async throws {
        let sandbox = try BulkSandbox()
        let zip = try sandbox.archive([("First.wav", Data(ImportFixtures.wav)), ("Second.mp3", Data(ImportFixtures.mp3))])
        let committed = BulkEvent(), release = BulkEvent()
        let task = Task {
            await sandbox.service().run([zip], imported: { _ in committed.signal(); await release.wait() })
        }
        await committed.wait()
        task.cancel(); release.signal()
        let report = await task.value
        #expect(report.cancelled)
        #expect(report.summary.imported == 1)
        #expect(await sandbox.notes.all().count == 1)
        #expect(try sandbox.scratchContents().isEmpty)
    }

    @Test func directoryFailuresAndEmptyArchivesAreDistinct() async throws {
        let sandbox = try BulkSandbox()
        let zip = try sandbox.archive([("README.txt", Data("English fixture".utf8))])
        let empty = await sandbox.service().run([zip])
        #expect(empty.archives == [.empty]); #expect(empty.summary.unsupported == 1)
        let limited = await sandbox.service(limits: ZIPLimits(entries: 0)).run([zip])
        #expect(limited.archives == [.tooLarge])
        let bad = try sandbox.file("broken.zip", Data("Not a ZIP".utf8))
        #expect(await sandbox.service().run([bad]).archives == [.damaged])
        #expect(try sandbox.scratchContents().isEmpty)
    }

    @Test func oneDamagedMemberDoesNotDiscardOtherGoodNotes() async throws {
        for corruptPayload in [false, true] {
            let sandbox = try BulkSandbox()
            let zip = try sandbox.archive([("Broken.wav", Data(ImportFixtures.wav)), ("Good.mp3", Data(ImportFixtures.mp3))])
            var data = try Data(contentsOf: zip)
            if corruptPayload {
                // Keep both headers/directory intact, but make the first member fail its declared CRC.
                let payload = try #require(data.range(of: Data(ImportFixtures.wav)))
                data[payload.upperBound - 1] ^= 1
            } else {
                data[0] = 0 // Only the first local header is damaged.
            }
            try data.write(to: zip)
            let report = await sandbox.service().run([zip])
            #expect(report.archives.isEmpty)
            #expect(report.summary.failed == 1)
            #expect(report.summary.imported == 1)
            #expect(await sandbox.notes.all().first?.title == "Good")
            #expect(try sandbox.scratchContents().isEmpty)
        }
    }

    @Test func duplicateSelectionFailsBeforePreparingOrWritingAnyMember() async throws {
        let sandbox = try BulkSandbox()
        let note = Note(title: "English meeting")
        let service = BulkExportService(folder: sandbox.scratch) { _, _ in
            Issue.record("An invalid selection must fail before preparing notes")
            throw ExportError.cannotSave
        }
        await #expect(throws: ExportError.noNote) { try await service.export([note, note]) }
        #expect(!FileManager.default.fileExists(atPath: sandbox.scratch.path))
    }

    @Test func perMemberLimitSkipsOnlyThatMemberAndProgressSurvivesAnEmptyArchive() async throws {
        let sandbox = try BulkSandbox()
        let zip = try sandbox.archive([("Too big.wav", Data(ImportFixtures.wav)), ("README.txt", Data())])
        let report = await sandbox.service(memberLimit: 1).run([zip])
        #expect(report.archives.isEmpty)
        #expect(report.summary.failed == 1)
        #expect(report.summary.unsupported == 1)
        #expect(await sandbox.notes.all().isEmpty)
        #expect(sandbox.audio.inspections == 0)
        let empty = try sandbox.archive([])
        let plain = try sandbox.file("English.wav", Data(ImportFixtures.wav))
        let trace = BulkProgressTrace()
        let finished = await sandbox.service().run([empty, plain], progress: { await trace.append($0) })
        #expect(finished.archives == [.empty])
        #expect(finished.summary.imported == 1)
        #expect(await trace.values.last == TransferProgress(done: 2, total: 2))
        #expect(try sandbox.scratchContents().isEmpty)
    }

    @Test func longArchiveBaseNamesNeverBecomeFilesystemPaths() async throws {
        let sandbox = try BulkSandbox()
        let title = String(repeating: "English ", count: 45)
        let zip = try sandbox.archive([(title + ".wav", Data(ImportFixtures.wav))])
        let report = await sandbox.service().run([zip])
        #expect(report.summary.imported == 1)
        let note = try #require(await sandbox.notes.all().first)
        #expect(note.title == ImportTitles.title(displayName: title + ".wav"))
        #expect(note.audioFilename == "source.wav")
        #expect(try sandbox.scratchContents().isEmpty)
    }

    @Test func exportFailureAfterAMemberRemovesEverythingAndNeverPublishesPartialZIP() async throws {
        let sandbox = try BulkSandbox()
        let source = try sandbox.file("original.wav", Data(ImportFixtures.wav))
        let folder = sandbox.folder.appendingPathComponent("exports")
        let first = Note(title: "English first"), missing = Note(title: "English missing")
        let service = BulkExportService(folder: folder) { note, target in
            if note.id == missing.id { throw ExportError.noNote }
            return try await BulkExportService.copyOriginal(source, to: target.appendingPathComponent("original.wav"))
        }
        await #expect(throws: ExportError.noNote) { try await service.export([first, missing]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(try Data(contentsOf: source) == Data(ImportFixtures.wav))
    }

    @Test func exportsEverySelectionMemberStoredAndResolvesNameCollisions() async throws {
        let sandbox = try BulkSandbox()
        var one = Note(title: "English meeting", audioFilename: "source.wav")
        one.audio = .plain
        let two = Note(title: "english MEETING", audioFilename: "source.wav")
        let bytes = Data(ImportFixtures.wav)
        let source = try sandbox.file("original.wav", bytes)
        let exports = sandbox.folder.appendingPathComponent("exports")
        let service = BulkExportService(folder: exports) { _, folder in
            try await BulkExportService.copyOriginal(source, to: folder.appendingPathComponent("original.wav"))
        }
        let url = try await service.export([one, two])
        let zip = try ZIPArchive(url: url)
        #expect(zip.entries.map(\.name) == ["English meeting.wav", "english MEETING (2).wav"])
        for entry in zip.entries {
            #expect(entry.method == 0)
            var data = Data()
            try zip.read(entry, remainingBytes: 20 << 30) { data.append($0) }
            #expect(data == bytes)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["Cassini.zip"])
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func exportCancellationDuringPreparationRemovesPartialArchive() async throws {
        let sandbox = try BulkSandbox()
        let arrived = BulkEvent(), release = BulkEvent()
        let folder = sandbox.folder.appendingPathComponent("exports")
        let service = BulkExportService(folder: folder) { _, target in
            arrived.signal(); await release.wait(); try Task.checkCancellation()
            return target.appendingPathComponent("unused.wav")
        }
        let task = Task { try await service.export([Note(title: "English meeting")]) }
        await arrived.wait(); task.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func cancellationReachesAlreadyExecutingBlockingWork() async throws {
        let arrived = BulkEvent(), release = DispatchSemaphore(value: 0)
        let task = Task {
            try await ArchiveWork.run { cancel in
                arrived.signal(); release.wait(); try cancel.check()
            }
        }
        await arrived.wait(); task.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationWinsOverAnIOErrorFromTheExecutingWorker() async throws {
        let arrived = BulkEvent(), release = DispatchSemaphore(value: 0)
        let task = Task {
            try await ArchiveWork.run { _ -> Void in
                arrived.signal(); release.wait()
                throw CocoaError(.fileReadUnknown)
            }
        }
        await arrived.wait(); task.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func namingAndOriginalAudioPolicyHaveNoTranscriptSideEffects() {
        var names = ArchiveNames()
        #expect(names.next(title: "English", extension: "opus") == "English.opus")
        #expect(names.next(title: "English (2)", extension: "opus") == "English (2).opus")
        #expect(names.next(title: "ENGLISH", extension: "opus") == "ENGLISH (3).opus")
        #expect(ArchiveContents.preservesOriginal(Note(title: "Audio only")))
        var transcribed = Note(title: "English meeting")
        transcribed.transcript = [.init(text: "English fixture", start: 0, end: 1)]
        #expect(!ArchiveContents.preservesOriginal(transcribed))
        var opaque = Note(title: "Newer document")
        opaque.document = DocumentInfo(state: .unknownFormat)
        #expect(ArchiveContents.preservesOriginal(opaque))
    }
}
