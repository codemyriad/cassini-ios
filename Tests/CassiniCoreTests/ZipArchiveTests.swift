@testable import CassiniCore
import CZlib
import Foundation
import Testing

private struct ZIPFixture {
    var name = "notes/English note.opus"
    var body = Data("Hello, a synthetic English recording.".utf8)
    var compressed: Data?
    var flags: UInt16 = 0x800
    var method: UInt16 = 0
    var wide = false
    var descriptor = false
    var descriptorSignature = true
    var declaredSize: UInt64?
    var declaredCompressedSize: UInt64?
    var declaredCRC: UInt32?
    var external: UInt32 = 0
    var localName: String?

    func data() -> Data {
        let payload = compressed ?? body
        let size = declaredSize ?? UInt64(body.count)
        let compressedSize = declaredCompressedSize ?? UInt64(payload.count)
        let crc = declaredCRC ?? body.withUnsafeBytes { bytes in
            UInt32(CZlib.crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, uInt(body.count)))
        }
        let allFlags = flags | (descriptor ? 8 : 0)
        let nameBytes = Data(name.utf8), localNameBytes = Data((localName ?? name).utf8)
        var extra = Data()
        if wide { extra.p16(1); extra.p16(16); extra.p64(size); extra.p64(compressedSize) }
        var output = Data()
        output.p32(0x04034b50); output.p16(wide ? 45 : 20); output.p16(allFlags); output.p16(method)
        output.p16(0); output.p16(0x21); output.p32(descriptor ? 0 : crc)
        output.p32(wide ? 0xffff_ffff : descriptor ? 0 : UInt32(compressedSize))
        output.p32(wide ? 0xffff_ffff : descriptor ? 0 : UInt32(size))
        output.p16(UInt16(localNameBytes.count)); output.p16(UInt16(extra.count)); output.append(localNameBytes); output.append(extra)
        output.append(payload)
        if descriptor {
            if descriptorSignature { output.p32(0x08074b50) }
            output.p32(crc)
            if wide { output.p64(compressedSize); output.p64(size) }
            else { output.p32(UInt32(compressedSize)); output.p32(UInt32(size)) }
        }
        let centralOffset = UInt64(output.count)
        var centralExtra = Data()
        if wide { centralExtra.p16(1); centralExtra.p16(24); centralExtra.p64(size); centralExtra.p64(compressedSize); centralExtra.p64(0) }
        output.p32(0x02014b50); output.p16(0x32d); output.p16(wide ? 45 : 20); output.p16(allFlags); output.p16(method)
        output.p16(0); output.p16(0x21); output.p32(crc)
        output.p32(wide ? 0xffff_ffff : UInt32(compressedSize)); output.p32(wide ? 0xffff_ffff : UInt32(size))
        output.p16(UInt16(nameBytes.count)); output.p16(UInt16(centralExtra.count)); output.p16(0)
        output.p16(0); output.p16(0); output.p32(external); output.p32(wide ? 0xffff_ffff : 0)
        output.append(nameBytes); output.append(centralExtra)
        let centralSize = UInt64(output.count) - centralOffset
        if wide {
            let zip64Offset = UInt64(output.count)
            output.p32(0x06064b50); output.p64(44); output.p16(45); output.p16(45); output.p32(0); output.p32(0)
            output.p64(1); output.p64(1); output.p64(centralSize); output.p64(centralOffset)
            output.p32(0x07064b50); output.p32(0); output.p64(zip64Offset); output.p32(1)
        }
        output.p32(0x06054b50); output.p16(0); output.p16(0); output.p16(wide ? 0xffff : 1); output.p16(wide ? 0xffff : 1)
        output.p32(wide ? 0xffff_ffff : UInt32(centralSize)); output.p32(wide ? 0xffff_ffff : UInt32(centralOffset)); output.p16(0)
        return output
    }

    static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                           zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZipArchiveError.damaged }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data), output = [UInt8](repeating: 0, count: max(64, data.count * 2 + 64))
        let status = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress; stream.avail_in = uInt(source.count)
                stream.next_out = target.baseAddress; stream.avail_out = uInt(target.count)
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw ZipArchiveError.damaged }
        return Data(output.prefix(Int(stream.total_out)))
    }
}

struct ZipArchiveTests {
    private func archive(_ fixture: ZIPFixture, in folder: URL) throws -> ZipArchive {
        let zip = folder.appendingPathComponent("input.zip")
        try fixture.data().write(to: zip)
        return try ZipArchive(url: zip)
    }

    @Test(arguments: [false, true])
    func classicAndZip64StoredEntriesExtractAsOriginalBytes(_ wide: Bool) throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.wide = wide
            let zip = try archive(fixture, in: folder)
            #expect(zip.entries.count == 1)
            let entry = try #require(zip.entries.first)
            #expect(entry.name == "notes/English note.opus")
            #expect(entry.baseName == "English note.opus")
            #expect(entry.uncompressedSize == Int64(fixture.body.count))
            #expect(!entry.isDirectory)
            let output = folder.appendingPathComponent("extracted")
            #expect(try zip.extract(entry, to: output, maxBytes: 1_000) == Int64(fixture.body.count))
            #expect(try Data(contentsOf: output) == fixture.body)
        }
    }

    @Test(arguments: [false, true])
    func classicAndZip64DescriptorsAreVerified(_ wide: Bool) throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.wide = wide; fixture.descriptor = true
            let zip = try archive(fixture, in: folder)
            let output = folder.appendingPathComponent("output")
            _ = try zip.extract(#require(zip.entries.first), to: output, maxBytes: 1_000)
            #expect(try Data(contentsOf: output) == fixture.body)
        }
    }

    @Test(arguments: [false, true])
    func signaturelessDescriptorsKeepCrcMagicUnambiguous(_ wide: Bool) throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.wide = wide; fixture.descriptor = true; fixture.descriptorSignature = false
            let zip = try archive(fixture, in: folder)
            let output = folder.appendingPathComponent("output")
            _ = try zip.extract(#require(zip.entries.first), to: output, maxBytes: 1_000)
            #expect(try Data(contentsOf: output) == fixture.body)
            // This real payload's CRC equals the optional signature. Both layouts must extract successfully.
            fixture.body = Data([0xac, 0x0a, 0x7a, 0xd5])
            let magic = try archive(fixture, in: folder)
            #expect(magic.entries.count == 1)
            let extracted = folder.appendingPathComponent("magic")
            _ = try magic.extract(#require(magic.entries.first), to: extracted, maxBytes: 1_000)
            #expect(try Data(contentsOf: extracted) == fixture.body)
        }
    }

    @Test func offsetOnlyZip64CentralRecordRequiresVersion45() {
        let name = Data("English.opus".utf8)
        let offset: UInt64 = 0x1_0000_0010
        let record = ZipArchive.centralDirectoryRecord(name: name, size: 32, localOffset: offset, crc: 123)
        #expect(record.q16(6) == 45)
        #expect(record.q32(20) == 32)
        #expect(record.q32(24) == 32)
        #expect(record.q32(42) == 0xffff_ffff)
        let extra = 46 + name.count
        #expect(record.q16(extra) == 1)
        #expect(record.q16(extra + 2) == 8)
        #expect(record.q64(extra + 4) == offset)
        let classic = ZipArchive.centralDirectoryRecord(name: name, size: 32, localOffset: 0, crc: 123)
        #expect(classic.q16(6) == 20)
    }

    @Test func deflateUsesStreamingAndChecksCrc() throws {
        try withTemporaryDirectory { folder in
            // Incompressible enough to stay below the D96 100:1 archive limit.
            var fixture = ZIPFixture()
            fixture.body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8) ^ ($0 >> 16)) })
            fixture.method = 8; fixture.compressed = try ZIPFixture.deflate(fixture.body)
            let zip = try archive(fixture, in: folder)
            let output = folder.appendingPathComponent("output")
            _ = try zip.extract(#require(zip.entries.first), to: output, maxBytes: 1_000_000)
            #expect(try Data(contentsOf: output) == fixture.body)
        }
    }

    @Test(arguments: ["../escape.opus", "notes/../escape.opus", "/absolute.opus", "C:\\absolute.opus", "\\\\server\\note.opus"])
    func unsafePathsRefuseWholeArchiveBeforeExtraction(_ path: String) throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.name = path
            #expect(throws: ZipArchiveError.unsafePaths) { try archive(fixture, in: folder) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["input.zip"])
        }
    }

    @Test(arguments: [UInt16(1), UInt16(0x40), UInt16(0x2000)])
    func anyEncryptionFlagRefusesTheArchive(_ flag: UInt16) throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.flags |= flag
            #expect(throws: ZipArchiveError.encrypted) { try archive(fixture, in: folder) }
        }
    }

    @Test func symlinksAndMismatchedLocalHeadersAreRefused() throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.external = UInt32(0xa1ff) << 16
            #expect(throws: ZipArchiveError.unsafePaths) { try archive(fixture, in: folder) }
            fixture.external = 0; fixture.localName = "other/English note.opus"
            #expect(throws: ZipArchiveError.damaged) { try archive(fixture, in: folder) }
        }
    }

    @Test func advertisedBombAndTotalLimitsFailBeforeBodiesAreRead() throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.method = 8; fixture.declaredSize = UInt64(fixture.body.count * 101)
            #expect(throws: ZipArchiveError.tooLarge) { try archive(fixture, in: folder) }
            fixture.declaredSize = ZipArchive.maxUncompressedBytes + 1; fixture.wide = true
            #expect(throws: ZipArchiveError.tooLarge) { try archive(fixture, in: folder) }
            var tooMany = ZIPFixture().data()
            tooMany.replaceSubrange(tooMany.count - 14..<tooMany.count - 10, with: [0xd1, 0x07, 0xd1, 0x07])
            let url = folder.appendingPathComponent("many.zip"); try tooMany.write(to: url)
            #expect(throws: ZipArchiveError.tooLarge) { try ZipArchive(url: url) }
        }
    }

    @Test func crcAndActualLengthFailuresRemovePartialOutput() throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.declaredCRC = 0
            var zip = try archive(fixture, in: folder)
            let output = folder.appendingPathComponent("output")
            #expect(throws: ZipArchiveError.damaged) { try zip.extract(#require(zip.entries.first), to: output, maxBytes: 1_000) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            fixture.declaredCRC = nil; fixture.method = 8; fixture.compressed = try ZIPFixture.deflate(fixture.body)
            fixture.declaredSize = UInt64(fixture.body.count - 1)
            zip = try archive(fixture, in: folder)
            #expect(throws: ZipArchiveError.tooLarge) { try zip.extract(#require(zip.entries.first), to: output, maxBytes: 1_000) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func truncatedAndTrailingCompressedBodiesAreRefused() throws {
        try withTemporaryDirectory { folder in
            var fixture = ZIPFixture(); fixture.method = 8; fixture.compressed = try ZIPFixture.deflate(fixture.body)
            for trailing in [false, true] {
                var broken = fixture
                if trailing { broken.compressed?.append(0) } else { broken.compressed?.removeLast() }
                let zip = try archive(broken, in: folder)
                #expect(throws: ZipArchiveError.damaged) {
                    try zip.extract(#require(zip.entries.first), to: folder.appendingPathComponent("output"), maxBytes: 1_000)
                }
            }
            let url = folder.appendingPathComponent("truncated.zip")
            try fixture.data().dropLast().write(to: url)
            #expect(throws: ZipArchiveError.damaged) { try ZipArchive(url: url) }
        }
    }

    @Test func singleEntryCapDoesNotCreateAFileAndExistingDestinationsStayUntouched() throws {
        try withTemporaryDirectory { folder in
            let zip = try archive(ZIPFixture(), in: folder)
            let entry = try #require(zip.entries.first)
            let output = folder.appendingPathComponent("output")
            #expect(throws: ZipArchiveError.tooLarge) { try zip.extract(entry, to: output, maxBytes: 1) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            let original = Data("Keep this existing file".utf8); try original.write(to: output)
            #expect(throws: (any Error).self) { try zip.extract(entry, to: output, maxBytes: 1_000) }
            #expect(try Data(contentsOf: output) == original)
        }
    }

    @Test func writerStoresUtf8NamesAndOriginalBytesWithoutCompression() throws {
        try withTemporaryDirectory { folder in
            let first = folder.appendingPathComponent("source"), second = folder.appendingPathComponent("second")
            let body = Data("A short English sample".utf8); try body.write(to: first); try Data().write(to: second)
            let output = folder.appendingPathComponent("export.zip")
            try ZipArchive.write([ZipSource(url: first, name: "Plan café.opus"), ZipSource(url: second, name: "Empty.wav")], to: output)
            let zip = try ZipArchive(url: output)
            #expect(zip.entries.map(\.name) == ["Plan café.opus", "Empty.wav"])
            for (index, entry) in zip.entries.enumerated() {
                #expect(entry.compressedSize == entry.uncompressedSize)
                let destination = folder.appendingPathComponent("entry-\(index)")
                _ = try zip.extract(entry, to: destination, maxBytes: 1_000)
                #expect(try Data(contentsOf: destination) == (index == 0 ? body : Data()))
            }
        }
    }

    @Test func overlappingBodiesAndUnsupportedMethodsAreRejectedUpfront() throws {
        try withTemporaryDirectory { folder in
            let base = ZIPFixture().data()
            let end = base.count - 22
            let directoryOffset = Int(base.q32(end + 16))
            let central = Data(base[directoryOffset..<end])
            var duplicate = Data(base.prefix(directoryOffset)); duplicate.append(central); duplicate.append(central)
            duplicate.p32(0x06054b50); duplicate.p16(0); duplicate.p16(0); duplicate.p16(2); duplicate.p16(2)
            duplicate.p32(UInt32(central.count * 2)); duplicate.p32(UInt32(directoryOffset)); duplicate.p16(0)
            let file = folder.appendingPathComponent("overlapping.zip"); try duplicate.write(to: file)
            #expect(throws: ZipArchiveError.damaged) { try ZipArchive(url: file) }
            var fixture = ZIPFixture(); fixture.method = 99
            #expect(throws: ZipArchiveError.damaged) { try archive(fixture, in: folder) }
        }
    }

    @Test func zip64WriterUsesTheSameCheckedReaderWithoutGigabyteFixtures() throws {
        try withTemporaryDirectory { folder in
            let source = folder.appendingPathComponent("source")
            let body = Data("An English sample in ZIP64".utf8); try body.write(to: source)
            let destination = folder.appendingPathComponent("zip64.zip")
            try ZipArchive.write([ZipSource(url: source, name: "English.opus")], to: destination, onChunk: nil, forceZIP64: true)
            let zip = try ZipArchive(url: destination)
            let entry = try #require(zip.entries.first)
            let extracted = folder.appendingPathComponent("extracted")
            _ = try zip.extract(entry, to: extracted, maxBytes: 1_000)
            #expect(try Data(contentsOf: extracted) == body)
            let bytes = try Data(contentsOf: destination)
            #expect(bytes.containsSequence(Data([0x50, 0x4b, 0x06, 0x06])))
        }
    }

    @Test func writerRejectsUnsafeDuplicatesAndNeverRemovesExistingOutput() throws {
        try withTemporaryDirectory { folder in
            let source = folder.appendingPathComponent("source"); try Data("Hello".utf8).write(to: source)
            let destination = folder.appendingPathComponent("archive.zip")
            #expect(throws: ZipArchiveError.unsafePaths) {
                try ZipArchive.write([ZipSource(url: source, name: "../unsafe.opus")], to: destination)
            }
            #expect(throws: ZipArchiveError.unsafePaths) {
                try ZipArchive.write([ZipSource(url: source, name: "Note.opus"), ZipSource(url: source, name: "Note.opus")], to: destination)
            }
            #expect(throws: ZipArchiveError.empty) { try ZipArchive.write([], to: destination) }
            let original = Data("Keep the existing archive".utf8); try original.write(to: destination)
            #expect(throws: (any Error).self) {
                try ZipArchive.write([ZipSource(url: source, name: "English.opus")], to: destination)
            }
            #expect(try Data(contentsOf: destination) == original)
        }
    }

    @Test func cancellationAtAnActualChunkRemovesExtractionAndExportFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zip-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var fixture = ZIPFixture(); fixture.body = Data(repeating: 42, count: ZipArchive.bufferBytes * 3)
        let zip = try archive(fixture, in: folder)
        let entry = try #require(zip.entries.first)
        let extracted = folder.appendingPathComponent("extracted")
        let extraction = Task.detached {
            try zip.extract(entry, to: extracted, maxBytes: 1_000_000, onChunk: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await extraction.value; Issue.record("Extraction ignored cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: extracted.path))
        let source = folder.appendingPathComponent("source"); try fixture.body.write(to: source)
        let output = folder.appendingPathComponent("output.zip")
        let export = Task.detached {
            try ZipArchive.write([ZipSource(url: source, name: "English note.wav")], to: output,
                                 onChunk: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { try await export.value; Issue.record("Export ignored cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

private extension Data {
    func q16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func q64(_ index: Int) -> UInt64 { UInt64(q32(index)) | UInt64(q32(index + 4)) << 32 }
    func q32(_ index: Int) -> UInt32 {
        UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
    func containsSequence(_ sequence: Data) -> Bool { range(of: sequence) != nil }

    mutating func p16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func p32(_ value: UInt32) { p16(UInt16(truncatingIfNeeded: value)); p16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func p64(_ value: UInt64) { p32(UInt32(truncatingIfNeeded: value)); p32(UInt32(truncatingIfNeeded: value >> 32)) }
}
