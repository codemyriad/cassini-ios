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

    @Test(arguments: ["../English.wav", "/English.wav", "C:/English.wav", "folder/../English.wav", "folder\\English.wav"])
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
    @Test func pythonReadsTheStoredZIP64OutputAndVerifiesEveryCRC() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("zip-interop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try one(folder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import sys,zipfile
        with zipfile.ZipFile(sys.argv[1]) as z:
            assert z.namelist()==['English.wav']
            assert all(e.compress_type==zipfile.ZIP_STORED for e in z.infolist())
            assert z.testzip() is None
            assert z.read('English.wav')==b'English sample'
        """, url.path]
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
