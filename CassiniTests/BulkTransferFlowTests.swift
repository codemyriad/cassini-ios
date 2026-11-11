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
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: raw)), wav)
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
        }
    }
}
