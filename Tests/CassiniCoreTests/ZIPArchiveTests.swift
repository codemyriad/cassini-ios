@testable import CassiniCore
import Foundation
import Testing
import CryptoKit

@Suite struct ZIPArchiveTests {
    private func one(_ folder: URL, bytes: Data = Data("English sample".utf8), name: String = "English.wav") throws -> URL {
        let source = folder.appendingPathComponent("source")
        try bytes.write(to: source)
        let url = folder.appendingPathComponent("notes.zip")
        let writer = try StoredZIPWriter(url: url)
        try writer.add(file: source, name: name); try writer.finish()
        return url
    }
    @Test func storedZIP64RoundTripStreamsBoundedChunks() throws {
        try withTemporaryDirectory { folder in
            let source = folder.appendingPathComponent("source")
            let data = Data((0..<(3 * ZIPArchive.chunkBytes + 9)).map { UInt8(truncatingIfNeeded: $0 * 17) })
            try data.write(to: source)
            let url = folder.appendingPathComponent("notes.zip")
            let writer = try StoredZIPWriter(url: url)
            try writer.add(file: source, name: "English meeting.wav")
            try writer.finish()
            let archive = try ZIPArchive(url: url)
            #expect(archive.entries.count == 1)
            let entry = try #require(archive.entries.first)
            #expect(entry.name == "English meeting.wav")
            #expect(entry.method == 0)
            #expect(entry.expandedBytes == UInt64(data.count))
            var read = Data()
            try archive.read(entry, remainingBytes: 20 << 30) { chunk in
                #expect(chunk.count <= ZIPArchive.chunkBytes)
                read.append(chunk)
            }
            #expect(read == data)
        }
    }

    @Test func everyClassicEOCDSentinelUsesTheZIP64Directory() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder)
            let original = try Data(contentsOf: url)
            let zip64 = try #require(original.range(of: Data([0x50, 0x4b, 6, 6]))).lowerBound
            let end = original.count - 22
            for field in [4, 6, 8, 10, 12, 16] {
                var bytes = original
                func put16(_ offset: Int, _ value: UInt16) { var d = Data(); d.zip16(value); bytes.replaceSubrange((end + offset)..<(end + offset + 2), with: d) }
                func put32(_ offset: Int, _ value: UInt32) { var d = Data(); d.zip32(value); bytes.replaceSubrange((end + offset)..<(end + offset + 4), with: d) }
                put16(4, 0); put16(6, 0); put16(8, 1); put16(10, 1)
                put32(12, UInt32(original.z64(zip64 + 40))); put32(16, UInt32(original.z64(zip64 + 48)))
                if field < 12 { put16(field, .max) } else { put32(field, .max) }
                try bytes.write(to: url)
                do {
                    let zip = try ZIPArchive(url: url)
                    var result = Data()
                    try zip.read(try #require(zip.entries.first), remainingBytes: 100) { result.append($0) }
                    #expect(result == Data("English sample".utf8))
                } catch { Issue.record("EOCD sentinel at offset \(field) must use ZIP64: \(error)") }
            }
            var allSentinels = original
            for offset in 4..<20 { allSentinels[end + offset] = 0xff }
            try allSentinels.write(to: url)
            #expect(try ZIPArchive(url: url).entries.count == 1)
            var multipleDisks = original
            multipleDisks[zip64 + 16] = 1
            try multipleDisks.write(to: url)
            #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
        }
    }

    @Test func localAndCentralDescriptorEncodingAndOptionFlagsMayDiffer() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder)
            let original = try Data(contentsOf: url)
            let central = try #require(original.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
            for flags: (UInt16, UInt16) in [(8, 0), (0, 8), (0, 0x800), (2, 0)] {
                var bytes = original
                var local = Data(); local.zip16(flags.0)
                var directory = Data(); directory.zip16(flags.1)
                bytes.replaceSubrange(6..<8, with: local)
                bytes.replaceSubrange((central + 8)..<(central + 10), with: directory)
                try bytes.write(to: url)
                let zip = try ZIPArchive(url: url)
                var result = Data()
                do {
                    try zip.read(try #require(zip.entries.first), remainingBytes: 100) { result.append($0) }
                    #expect(result == Data("English sample".utf8))
                } catch { Issue.record("Harmless header flags \(flags) must not lose a member: \(error)") }
            }
        }
    }

    @Test func independentlyDeflatedFixtureMatchesItsDigest() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("deflated.zip")
            try ZIPDeflateFixture.data.write(to: url)
            let archive = try ZIPArchive(url: url)
            let entry = try #require(archive.entries.first)
            #expect(entry.name == "English.wav")
            var hash = SHA256(), chunks = 0
            let size = try archive.read(entry, remainingBytes: 20 << 30) {
                #expect($0.count <= ZIPArchive.chunkBytes); chunks += 1; hash.update(data: $0)
            }
            #expect(size == 204_800); #expect(chunks >= 4)
            #expect(hash.finalize().map { String(format: "%02x", $0) }.joined() == ZIPDeflateFixture.digest)
        }
    }

    @Test(arguments: ["../English.wav", "/English.wav", "C:/English.wav", "folder/../English.wav", "folder\\..\\English.wav", "\\\\server\\English.wav"])
    func pathsAreRefusedBeforeExtraction(_ path: String) throws {
        #expect(throws: ZIPFailure.unsafePaths) { try ZIPArchive.checkPath(path) }
    }

    @Test func corruptCRCAndFalseExpandedSizeAreIndividualFailures() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder)
            var data = try Data(contentsOf: url)
            let directory = try #require(data.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
            data[directory + 16] ^= 1
            try data.write(to: url)
            let archive = try ZIPArchive(url: url)
            #expect(throws: ZIPFailure.entry) { try archive.read(archive.entries[0], remainingBytes: 20 << 30) { _ in } }
        }
    }

    @Test func directoryLimitsAreInclusiveAndRuntimeBudgetIsIndependent() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder, bytes: Data(repeating: 9, count: 100))
            _ = try ZIPArchive(url: url, limits: ZIPLimits(entries: 1, expandedBytes: 100))
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive(url: url, limits: ZIPLimits(entries: 0)) }
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive(url: url, limits: ZIPLimits(expandedBytes: 99)) }
            let archive = try ZIPArchive(url: url)
            #expect(throws: ZIPFailure.tooLarge) { try archive.read(archive.entries[0], remainingBytes: 99) { _ in } }
            #expect(throws: Never.self) { try ZIPArchive.checkRatio(100, 1, 100) }
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive.checkRatio(101, 1, 100) }
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive.checkRatio(1, 0, 100) }
        }
    }

    @Test func encryptedDirectoryAndLocalHeaderAreBothRefused() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder)
            let original = try Data(contentsOf: url)
            let directory = try #require(original.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
            for position in [6, directory + 8] {
                var data = original; data[position] |= 1; try data.write(to: url)
                #expect(throws: ZIPFailure.encrypted) { try ZIPArchive(url: url) }
            }
        }
    }

    @Test func truncationAndOutOfBoundsDirectoryAreRefused() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder)
            let original = try Data(contentsOf: url)
            for n in [0, 4, 21, original.count - 1] {
                try original.prefix(n).write(to: url)
                #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
            }
            var data = original
            let end = try #require(data.range(of: Data([0x50, 0x4b, 6, 6]))).lowerBound
            for n in 0..<8 { data[end + 48 + n] = 0xff }
            try data.write(to: url)
            #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
        }
    }

    @Test func memberReadAndWriteCancellationStopAtAChunkEvent() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder, bytes: Data(repeating: 3, count: 3 * ZIPArchive.chunkBytes))
            let archive = try ZIPArchive(url: url)
            var delivered = 0
            #expect(throws: CancellationError.self) {
                try archive.read(archive.entries[0], remainingBytes: 20 << 30,
                                 check: { if delivered > 0 { throw CancellationError() } }) { delivered += $0.count }
            }
            #expect(delivered == ZIPArchive.chunkBytes)
            let writer = try StoredZIPWriter(url: folder.appendingPathComponent("cancelled.zip"))
            var checks = 0
            #expect(throws: CancellationError.self) {
                try writer.add(file: folder.appendingPathComponent("source"), name: "English.wav", check: {
                    checks += 1; if checks == 3 { throw CancellationError() }
                })
            }
            #expect(checks == 3)
        }
    }

    @Test func ratioBombAndUnicodePathAliasesAreRefused() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("untrusted.zip")
            try ZIPDeflateFixture.ratioBomb.write(to: url)
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive(url: url) }
            try ZIPDeflateFixture.unicodeTraversal.write(to: url)
            #expect(throws: ZIPFailure.unsafePaths) { try ZIPArchive(url: url) }
        }
    }

    @Test func twoThousandEntriesAreAcceptedAndTheNextIsRefused() throws {
        try withTemporaryDirectory { folder in
            #expect(ZIPLimits().entries == 2_000)
            #expect(ZIPLimits().expandedBytes == 20_000_000_000)
            #expect(ZIPLimits().ratio == 100)
            let source = folder.appendingPathComponent("empty")
            try Data().write(to: source)
            let url = folder.appendingPathComponent("many.zip")
            let writer = try StoredZIPWriter(url: url)
            for n in 0..<2_000 { try writer.add(file: source, name: "English-\(n).wav") }
            #expect(throws: ZIPFailure.tooLarge) { try writer.add(file: source, name: "Excess.wav") }
            try writer.finish()
            #expect(try ZIPArchive(url: url).entries.count == 2_000)
            var bytes = try Data(contentsOf: url)
            let end = try #require(bytes.range(of: Data([0x50, 0x4b, 6, 6]))).lowerBound
            var count = Data(); count.zip64(2_001)
            bytes.replaceSubrange((end + 24)..<(end + 32), with: count)
            bytes.replaceSubrange((end + 32)..<(end + 40), with: count)
            try bytes.write(to: url)
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive(url: url) }
        }
    }

    @Test func falseExpandedSizeCannotMakeExtraBytesReachTheConsumer() throws {
        try withTemporaryDirectory { folder in
            let url = try one(folder, bytes: Data(repeating: 7, count: 100))
            var bytes = try Data(contentsOf: url)
            let directory = try #require(bytes.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
            let extra = directory + 46 + Int(bytes.z16(directory + 28))
            var size = Data(); size.zip64(1)
            bytes.replaceSubrange((extra + 4)..<(extra + 12), with: size)
            try bytes.write(to: url)
            let archive = try ZIPArchive(url: url)
            var delivered = 0, observed = 0
            #expect(throws: ZIPFailure.entry) {
                try archive.read(archive.entries[0], remainingBytes: 100, observed: { observed += $0 }) { delivered += $0.count }
            }
            #expect(observed == 100)
            #expect(delivered == 0)
        }
    }

    #if os(macOS)
    @Test func deflateExactChunkBoundaryAcceptsAnInputStarvedNonfinalBlock() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("zip-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await python("""
        import sys,random,zlib,struct,zipfile,io
        from pathlib import Path
        folder=Path(sys.argv[1]); data=bytes(random.Random(96).randbytes(65536))
        # Find a valid nonfinal deflate segment filling both the input and output chunk exactly.
        for n in range(1024):
         payload=bytes(n)+data[n:]
         c=zlib.compressobj(wbits=-15)
         first=c.compress(payload)+c.flush(zlib.Z_SYNC_FLUSH)
         if len(first)==65536:break
        else:raise AssertionError('Missing exact chunk-boundary fixture')
        tail=b'English fixture end'; raw=first+c.compress(tail)+c.flush(); plain=payload+tail
        name=b'English.wav';crc=zlib.crc32(plain);size=len(plain);packed=len(raw)
        local=struct.pack('<I5H3I2H',0x04034b50,20,0,8,0,0,crc,packed,size,len(name),0)+name+raw
        central=struct.pack('<I6H3I5H2I',0x02014b50,20,20,0,8,0,0,crc,packed,size,len(name),0,0,0,0,0,0)+name
        archive=local+central+struct.pack('<I4H2IH',0x06054b50,0,0,1,1,len(central),len(local),0)
        assert zipfile.ZipFile(io.BytesIO(archive)).read(name.decode())==plain
        (folder/'boundary.zip').write_bytes(archive);(folder/'expected').write_bytes(plain)
        """, arguments: [folder.path])
        let zip = try ZIPArchive(url: folder.appendingPathComponent("boundary.zip"))
        var output = Data()
        try zip.read(try #require(zip.entries.first), remainingBytes: 100_000) { output.append($0) }
        #expect(output == (try Data(contentsOf: folder.appendingPathComponent("expected"))))
    }

    @Test func pythonReadsTheStoredZIP64OutputAndVerifiesEveryCRC() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("zip-interop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try one(folder)
        try await python("""
        import sys,zipfile
        with zipfile.ZipFile(sys.argv[1]) as z:
            assert z.namelist()==['English.wav']
            assert all(e.compress_type==zipfile.ZIP_STORED for e in z.infolist())
            assert z.testzip() is None
            assert z.read('English.wav')==b'English sample'
        """, arguments: [url.path])
    }

    private func python(_ script: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script] + arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        let rc: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(rc == 0, "Python ZIP reader: \(message)")
    }
    #endif
}
