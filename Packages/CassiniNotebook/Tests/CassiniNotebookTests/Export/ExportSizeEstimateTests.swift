import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct ExportSizeEstimateTests {
    private func temporaryFile(named name: String, bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func oggOpusBytes(totalCount: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: max(64, totalCount))
        for (i, b) in Array("OggS".utf8).enumerated() { data[i] = b }
        data[26] = 1
        for (i, b) in Array("OpusHead".utf8).enumerated() { data[28 + i] = b }
        return data
    }

    @Test func opusImportUsesStoredFileSize() throws {
        let opusSize = 1_850_000
        let url = try temporaryFile(named: "meeting.opus", bytes: oggOpusBytes(totalCount: opusSize))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var note = Note(title: "Imported Opus", audioFilename: "meeting.opus")
        note.origin = .importedDocument
        note.duration = 60
        let estimate = ExportSizeEstimate.cassiniBytes(note: note, audioURL: url)
        #expect(estimate == Int64(opusSize))
        #expect(estimate.map { SizeText(bytes: $0).english() } == "2 MB")
    }

    @Test func m4aRecordingEstimatesFrom48kbpsOpusNotStoredM4aSize() throws {
        // An M4A file whose on-disk size (5 MB) differs from its 48 kbps Opus export (~1.8 MB for 5 min).
        var m4a = [UInt8](repeating: 0, count: 5_000_000)
        for (i, b) in Array("ftyp".utf8).enumerated() { m4a[4 + i] = b }
        let url = try temporaryFile(named: "audio.m4a", bytes: m4a)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var note = Note(title: "Voice memo", audioFilename: "audio.m4a")
        note.duration = 300
        note.transcript = [
            .init(text: "Hello everyone, welcome to the weekly sync.", start: 0, end: 5)
        ]
        let expected = Int64(300) * ExportSizeEstimate.opusBytesPerSecond
            + ExportSizeEstimate.containerOverheadBytes
            + Int64("Hello everyone, welcome to the weekly sync.".utf8.count)
        let estimate = ExportSizeEstimate.cassiniBytes(note: note, audioURL: url)
        #expect(estimate == expected)
        #expect(estimate.map { SizeText(bytes: $0).english() } == "2 MB")
    }

    @Test func wavImportEstimatesOpusSizeInsteadOfUncompressedWavSize() throws {
        // A 1-hour WAV would be >100 MB on disk; the 48 kbps Opus export is ~21 MB.
        var wav = [UInt8](repeating: 0, count: 100_000)
        for (i, b) in Array("RIFF".utf8).enumerated() { wav[i] = b }
        for (i, b) in Array("WAVE".utf8).enumerated() { wav[8 + i] = b }
        let url = try temporaryFile(named: "interview.wav", bytes: wav)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var note = Note(title: "Interview", audioFilename: "interview.wav")
        note.origin = .imported
        note.duration = 3_600
        let expected = Int64(3_600) * ExportSizeEstimate.opusBytesPerSecond
            + ExportSizeEstimate.containerOverheadBytes
        let estimate = ExportSizeEstimate.cassiniBytes(note: note, audioURL: url)
        #expect(estimate == expected)
        #expect(estimate.map { SizeText(bytes: $0).english() } == "21 MB")
    }

    @Test func missingAudioFileFallsBackToDurationEstimate() {
        var note = Note(title: "Offline note", audioFilename: "missing.m4a")
        note.duration = 600
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = Int64(600) * ExportSizeEstimate.opusBytesPerSecond
            + ExportSizeEstimate.containerOverheadBytes
        #expect(ExportSizeEstimate.cassiniBytes(note: note, audioURL: missing) == expected)
        #expect(ExportSizeEstimate.cassiniBytes(note: note, audioURL: nil) == expected)
    }

    @Test func zeroOrNegativeDurationWithoutOpusReturnsNil() {
        var note = Note(title: "Empty")
        note.duration = 0
        #expect(ExportSizeEstimate.cassiniBytes(note: note, audioURL: nil) == nil)
        note.duration = -10
        #expect(ExportSizeEstimate.cassiniBytes(note: note, audioURL: nil) == nil)
        note.duration = .nan
        #expect(ExportSizeEstimate.cassiniBytes(note: note, audioURL: nil) == nil)
    }
}
