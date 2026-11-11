import XCTest
import Foundation
import UniformTypeIdentifiers
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class BulkTransferFlowTests: XCTestCase {
    private let wav = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8) + [UInt8](repeating: 1, count: 100))

    func testPickerAcceptsZIPAndBatchPublishesItsFinalSummaryAfterLibraryAdoption() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        harness.graph.settings.autoTranscribe = false
        XCTAssertTrue(ImportStore.contentTypes.contains(.zip))
        let source = harness.root.appendingPathComponent("English.wav")
        try wav.write(to: source)
        let zip = harness.root.appendingPathComponent("English.zip")
        let writer = try StoredZIPWriter(url: zip)
        try writer.add(file: source, name: "English meeting.wav")
        try writer.add(file: source, name: "Duplicate.wav")
        try writer.finish()
        harness.graph.imports.start([zip, source])
        let batch = try XCTUnwrap(harness.graph.imports.batches.last)
        defer { batch.cancel() }
        let task = try XCTUnwrap(batch.task)
        let ended = expectation(description: "batch completed its imports and adopted the Library notes")
        Task { await task.value; ended.fulfill() }
        await fulfillment(of: [ended], timeout: 30)
        let report = try XCTUnwrap(batch.report)
        XCTAssertEqual(report.summary.imported, 1)
        XCTAssertEqual(report.summary.duplicates, 2)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(harness.graph.library.notes.count, 1)
        XCTAssertEqual(harness.graph.library.notes.first?.title, "English meeting")
        XCTAssertEqual(BulkTransferCopy.summary(report.summary).components(separatedBy: " · ").count, 2)
        XCTAssertFalse(BulkTransferCopy.summary(report.summary).contains("%"))
        XCTAssertNil(batch.task)
    }

    func testZIPExportContainsCompleteDocumentAndUnchangedOriginalAndDiscardsAfterSharing() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        let store = try XCTUnwrap(harness.graph.library.noteStore)
        var raw = Note(title: "English audio", audioFilename: "source.wav")
        raw.origin = .imported
        var document = Note(title: "English transcript", audioFilename: "source.wav")
        document.transcript = [.init(text: "English fixture", start: 0, end: 1)]
        document.language = "en"; document.status = .ready
        for note in [raw, document] {
            try await store.save(note)
            try wav.write(to: store.audioURL(for: note))
            harness.graph.library.adopt(note)
        }
        let before = harness.graph.library.notes
        let url = try await harness.graph.exports.exportArchive([raw.id, document.id], progress: { _ in })
        let zip = try ZIPArchive(url: url)
        XCTAssertEqual(zip.entries.map(\.name), ["English audio.wav", "English transcript.opus"])
        for entry in zip.entries {
            XCTAssertEqual(entry.method, 0)
            var bytes = Data()
            try zip.read(entry, remainingBytes: 20 << 30) { bytes.append($0) }
            if entry.name.hasSuffix(".wav") { XCTAssertEqual(bytes, wav) }
            else {
                let file = harness.root.appendingPathComponent("verified.opus")
                try bytes.write(to: file)
                let checked = CassiniDocument.readChecked(file)
                XCTAssertEqual(checked.state, .ok)
                XCTAssertEqual(checked.manifest?["meeting"]?.object?["title"]?.string, document.title)
                XCTAssertEqual(checked.selected()?.transcript?.words.map(\.text).joined(separator: " "), "English fixture")
            }
        }
        XCTAssertEqual(harness.graph.library.notes, before, "Export cannot edit or replace the notes being backed up")
        let item = harness.graph.exports.shareItem(url)
        item.onComplete?()
        await harness.graph.exports.waitForDiscards()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: raw)), wav)
    }

    func testCleanImportedDocumentsKeepExactBytesAndReimportAsDuplicates() async throws {
        let audio = FakeAudioProcessing()
        let harness = TestGraph(audio: audio)
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        harness.graph.settings.autoTranscribe = false
        let source = harness.root.appendingPathComponent("English.wav")
        try wav.write(to: source)
        var producer = Note(title: "English manifest title")
        producer.transcript = [.init(text: "English original words", start: 0, end: 1)]
        producer.language = "en"
        let portable = PortableExportService(audio: audio, provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
        let generated = try await portable.export(producer, original: source, playable: source, into: harness.root, filename: "generated")
        let document = CassiniDocument.readChecked(generated)
        XCTAssertEqual(document.state, .ok)
        var originals: [UUID: Data] = [:]
        let store = try XCTUnwrap(harness.graph.library.noteStore)
        for titleTag in ["", "TITLE=A stale optional tag"] {
            var comments = document.comments.filter { !$0.uppercased().hasPrefix("TITLE=") }
            if !titleTag.isEmpty { comments.append(titleTag) }
            let input = harness.root.appendingPathComponent(UUID().uuidString + ".opus")
            try OggOpus.rewrite(generated, tags: CassiniDocument.tagsPacket(comments), to: input)
            let outcome = await harness.graph.imports.importFile(input, opensNote: false).value
            let id = try XCTUnwrap(outcome?.noteID)
            originals[id] = try Data(contentsOf: input)
        }
        let rawOutcome = await harness.graph.imports.importFile(source, opensNote: false).value
        originals[try XCTUnwrap(rawOutcome?.noteID)] = wav
        let before = harness.graph.library.notes
        let metadata = try Dictionary(uniqueKeysWithValues: before.map { note in
            (note.id, try Data(contentsOf: store.directory(for: note.id).appendingPathComponent("note.json")))
        })
        let archive = try await harness.graph.exports.exportArchive(before.map(\.id), progress: { _ in })
        let zip = try ZIPArchive(url: archive)
        var archived: Set<Data> = []
        for entry in zip.entries {
            var bytes = Data()
            try zip.read(entry, remainingBytes: 1_000_000) { bytes.append($0) }
            archived.insert(bytes)
            XCTAssertTrue(originals.values.contains(bytes), "Clean documents must remain byte-identical, even without a matching TITLE tag")
        }
        XCTAssertEqual(archived, Set(originals.values))
        for note in before {
            XCTAssertEqual(try Data(contentsOf: store.originalAudioURL(for: note)), originals[note.id])
            XCTAssertEqual(try Data(contentsOf: store.directory(for: note.id).appendingPathComponent("note.json")), metadata[note.id])
        }
        XCTAssertEqual(harness.graph.library.notes, before)
        harness.graph.imports.start([archive])
        let batch = try XCTUnwrap(harness.graph.imports.batches.last)
        let task = try XCTUnwrap(batch.task)
        await task.value
        let report = try XCTUnwrap(batch.report)
        XCTAssertEqual(report.summary.duplicates, 3)
        XCTAssertEqual(report.summary.imported, 0)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(harness.graph.library.notes.count, 3)
        harness.graph.exports.discard(archive)
        await harness.graph.exports.waitForDiscards()

        // A local edit needs a new portable snapshot, while the stored original and metadata stay read-only.
        let editedID = try XCTUnwrap(before.first { $0.origin == .importedDocument }?.id)
        await harness.graph.library.commit(editedID) { note in
            let original = note.transcript[0]
            let revised = original.revised(text: "English locally edited words", speakerID: original.speakerID, speakers: note.speakers ?? [])
            note.revisePassage(original, to: revised, stamp: .init(date: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        let editedNote = try XCTUnwrap(harness.graph.library.note(editedID))
        let metadataURL = store.directory(for: editedID).appendingPathComponent("note.json")
        let editedMetadata = try Data(contentsOf: metadataURL)
        let changed = try await harness.graph.exports.exportArchive([editedID], progress: { _ in })
        let changedZIP = try ZIPArchive(url: changed)
        var changedBytes = Data()
        try changedZIP.read(try XCTUnwrap(changedZIP.entries.first), remainingBytes: 1_000_000) { changedBytes.append($0) }
        let verified = harness.root.appendingPathComponent("Edited English.opus")
        try changedBytes.write(to: verified)
        XCTAssertEqual(CassiniDocument.readChecked(verified).selected()?.transcript?.words.map(\.text).joined(separator: " "),
                       "English locally edited words")
        XCTAssertEqual(try Data(contentsOf: store.originalAudioURL(for: editedNote)), originals[editedID])
        XCTAssertEqual(try Data(contentsOf: metadataURL), editedMetadata)
        harness.graph.exports.discard(changed)
        await harness.graph.exports.waitForDiscards()
    }

    func testBatchStartClearsStaleFailureButCancelledPickerDoesNotAndNoSpaceIsSpecific() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        let imports = harness.graph.imports
        imports.tracker.recordFailure(.cannotOpen, displayName: "Old English file")
        imports.start([])
        XCTAssertEqual(imports.tracker.failure?.kind, .cannotOpen)
        let source = harness.root.appendingPathComponent("English.wav")
        try wav.write(to: source)
        let storage = try XCTUnwrap(harness.graph.environment.storage as? FakeStorage)
        storage.set(availableBytes: 0)
        imports.start([source])
        XCTAssertNil(imports.tracker.failure)
        let batch = try XCTUnwrap(imports.batches.last)
        let task = try XCTUnwrap(batch.task)
        await task.value
        guard case .noSpace = imports.tracker.failure?.kind else { return XCTFail("The localized storage-full notice must survive batch aggregation") }
        XCTAssertNotNil(batch.report?.storageFailure)
        XCTAssertTrue(harness.graph.library.notes.isEmpty)
    }

    func testExportAllExcludesRecoveredCapturesWithoutAudio() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        let store = try XCTUnwrap(harness.graph.library.noteStore)
        let good = Note(title: "Good", audioFilename: "audio.wav")
        var missing = Note(title: "Recovered without audio", audioFilename: "capture.caf")
        missing.audio = .unplayable(.interrupted)
        for note in [good, missing] { try await store.save(note); harness.graph.library.adopt(note) }
        try wav.write(to: store.audioURL(for: good))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: missing).path))
        let ids = ArchiveSelection.ids(harness.graph.library.notes)
        XCTAssertEqual(ids, [good.id])
        let output = try await harness.graph.exports.exportArchive(ids, progress: { _ in })
        let zip = try ZIPArchive(url: output)
        XCTAssertEqual(zip.entries.map(\.name), ["Good.wav"])
        var bytes = Data()
        try zip.read(try XCTUnwrap(zip.entries.first), remainingBytes: 1_000_000) { bytes.append($0) }
        XCTAssertEqual(bytes, wav)
        harness.graph.exports.discard(output)
        await harness.graph.exports.waitForDiscards()
    }

    func testArchiveRereadsACaptureRotatedBeforeItsTurn() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        let library = harness.graph.library
        let store = try XCTUnwrap(library.noteStore)
        let first = Note(title: "First", audioFilename: "audio.wav")
        let capture = Note(title: "Stopped recording", audioFilename: "capture.caf")
        for note in [first, capture] { try await store.save(note); library.adopt(note) }
        try wav.write(to: store.audioURL(for: first))
        let oldURL = store.audioURL(for: capture)
        try Data("Old capture".utf8).write(to: oldURL)
        let compressed = Data("Finished compressed recording".utf8)
        let output = try await harness.graph.exports.exportArchive([first.id, capture.id]) { progress in
            if progress.done == 1 {
                do {
                    try compressed.write(to: oldURL.deletingLastPathComponent().appendingPathComponent("audio.m4a"))
                    await library.commit(capture.id) { $0.audioFilename = "audio.m4a" }
                    try FileManager.default.removeItem(at: oldURL)
                } catch { XCTFail("Could not rotate fixture: \(error)") }
            }
        }
        let zip = try ZIPArchive(url: output)
        XCTAssertEqual(zip.entries.map(\.name), ["First.wav", "Stopped recording.m4a"])
        var bytes = Data()
        try zip.read(zip.entries[1], remainingBytes: 1_000_000) { bytes.append($0) }
        XCTAssertEqual(bytes, compressed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        harness.graph.exports.discard(output)
        await harness.graph.exports.waitForDiscards()
    }

    func testArchiveWaitsForFinalizationBeforeResolvingTheCapture() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        let library = harness.graph.library
        let store = try XCTUnwrap(library.noteStore)
        let note = Note(title: "Finalizing recording", audioFilename: "capture.caf")
        try await store.save(note); library.adopt(note)
        let oldURL = store.audioURL(for: note)
        try Data("Capture before compression".utf8).write(to: oldURL)
        let entered = expectation(description: "export reached recording finalization fence")
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let exporter = ExportStore(library: library, audio: FakeAudioProcessing(), folder: harness.graph.environment.exports,
                                   texts: ExportCopy.texts(locale: .init(identifier: "en_US"), timeZone: .gmt),
                                   audioReady: {
            entered.fulfill()
            for await _ in release.stream { break }
        }, ready: {})
        let exporting = Task { try await exporter.exportArchive([note.id], progress: { _ in }) }
        defer { exporting.cancel() }
        await fulfillment(of: [entered], timeout: 30)
        let compressed = Data("Final compressed bytes".utf8)
        try compressed.write(to: oldURL.deletingLastPathComponent().appendingPathComponent("audio.m4a"))
        await library.commit(note.id) { $0.audioFilename = "audio.m4a" }
        try FileManager.default.removeItem(at: oldURL)
        release.continuation.yield(())
        let output = try await exporting.value
        let zip = try ZIPArchive(url: output)
        XCTAssertEqual(zip.entries.map(\.name), ["Finalizing recording.m4a"])
        var bytes = Data()
        try zip.read(try XCTUnwrap(zip.entries.first), remainingBytes: 1_000_000) { bytes.append($0) }
        XCTAssertEqual(bytes, compressed)
        exporter.discard(output)
        await exporter.waitForDiscards()
    }

    func testMissingSelectionIsNotSilentlyOmitted() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        do {
            _ = try await harness.graph.exports.exportArchive([UUID()], progress: { _ in })
            XCTFail("A missing selected note must fail the archive")
        } catch { XCTAssertEqual(error as? ExportError, .noNote) }
    }

    func testUnreadableOrNewerDocumentsAreBackedUpByteForByte() async throws {
        let harness = TestGraph(audio: FakeAudioProcessing())
        defer { harness.tearDown() }
        _ = await harness.graph.start()
        let store = try XCTUnwrap(harness.graph.library.noteStore)
        var note = Note(title: "Future English document", audioFilename: "document.opus")
        note.origin = .importedDocument
        note.audio = .unplayable(.unsupportedFormat)
        try await store.save(note)
        let original = Data("Opaque future document: must never be transcoded or silently replaced".utf8)
        try original.write(to: store.audioURL(for: note))
        for state in [DocumentState.unknownFormat, .unreadable, .invalidMetadata] {
            note.document = DocumentInfo(state: state)
            try await store.save(note)
            harness.graph.library.adopt(note)
            let url = try await harness.graph.exports.exportArchive([note.id], progress: { _ in })
            let zip = try ZIPArchive(url: url)
            var bytes = Data()
            try zip.read(try XCTUnwrap(zip.entries.first), remainingBytes: 20 << 30) { bytes.append($0) }
            XCTAssertEqual(bytes, original)
            harness.graph.exports.discard(url)
            await harness.graph.exports.waitForDiscards()
        }
    }
}
