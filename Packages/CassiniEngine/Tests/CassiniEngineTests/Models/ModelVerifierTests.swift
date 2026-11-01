import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// D16 §4: every installed model is hashed against its pins before its first use in each session (iOS checks all four
/// models; Android has no such check yet). Small real files with real hashes stand for a model.
@Suite struct ModelVerifierTests {
    private let one = Data("first file".utf8)
    private let two = Data(repeating: 7, count: 300_000)

    private var model: ModelDescriptor {
        ModelDescriptor("test-model", String(repeating: "e", count: 64),
                        [Artifact("one.bin", Int64(one.count), sha256(one)), Artifact("two.bin", Int64(two.count), sha256(two))])
    }

    /// The revision directory of `model` with the real files and notices.
    private func installed(_ root: URL) throws -> URL {
        let directory = model.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try one.write(to: directory.appendingPathComponent("one.bin"))
        try two.write(to: directory.appendingPathComponent("two.bin"))
        try Data("notices".utf8).write(to: directory.appendingPathComponent(ModelDescriptor.noticeFile))
        return directory
    }

    /// The real digest, counting the files it hashes.
    private func counting(_ count: Counter) -> ModelVerifier {
        ModelVerifier { file, cancelled, onBytes in
            _ = count.next()
            return try ArtifactFetcher.digest(file, onBytes: onBytes, cancelled: cancelled)
        }
    }

    @Test func theFirstLoadOfASessionHashesEveryFile() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        _ = try installed(folder.root)
        let hashed = Counter()
        let verifier = counting(hashed)
        var reported: [Int64] = []
        #expect(try verifier.verify(model, in: folder.root) { reported.append($0) })
        #expect(hashed.value == 2)
        #expect(reported.last == model.artifactBytes)
        #expect(reported == reported.sorted())
        #expect(verifier.isChecked(model, in: folder.root))
    }

    @Test func aSecondLoadInTheSameSessionHashesNothing() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        _ = try installed(folder.root)
        let hashed = Counter()
        let verifier = counting(hashed)
        #expect(try verifier.verify(model, in: folder.root))
        #expect(try verifier.verify(model, in: folder.root))
        #expect(hashed.value == 2)
        // A new session (a new process) checks again.
        verifier.reset()
        #expect(try verifier.verify(model, in: folder.root))
        #expect(hashed.value == 4)
    }

    @Test func aFreshInstallCountsAsChecked() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        _ = try installed(folder.root)
        let hashed = Counter()
        let verifier = counting(hashed)
        verifier.markVerified(model, in: folder.root)
        #expect(try verifier.verify(model, in: folder.root))
        #expect(hashed.value == 0)
        #expect(!verifier.isChecked(model, in: folder.root.appendingPathComponent("other")), "per model root")
    }

    @Test func aChangedFileRemovesTheRevisionAndAsksForTheDownloadAgain() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let directory = try installed(folder.root)
        // The same length, other bytes: only the hash can tell.
        var changed = two
        changed[1000] = 8
        try changed.write(to: directory.appendingPathComponent("two.bin"))
        let verifier = ModelVerifier()
        #expect(model.ready(in: folder.root))
        #expect(try !verifier.verify(model, in: folder.root))
        #expect(!model.ready(in: folder.root))
        #expect(!exists(directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path).isEmpty,
                "retired by rename, then deleted")
        #expect(!verifier.isChecked(model, in: folder.root))
        #expect(try !verifier.verify(model, in: folder.root), "not installed")
    }

    @Test func aCancelledCheckIsDoneAgainNextTime() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        _ = try installed(folder.root)
        let hashed = Counter()
        let verifier = counting(hashed)
        #expect(throws: CancellationError.self) { try verifier.verify(model, in: folder.root, cancelled: { true }) }
        #expect(!verifier.isChecked(model, in: folder.root))
        #expect(model.ready(in: folder.root), "a stopped check removes nothing")
        #expect(try verifier.verify(model, in: folder.root))
    }

    /// The flag is read between the blocks of a file, not only between files: a check stopped in the middle of a hash
    /// ends there, unrecorded.
    @Test func aCheckStopsBetweenTheBlocksOfAFile() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        _ = try installed(folder.root)
        let verifier = ModelVerifier()
        var stop = false
        var reported: [Int64] = []
        #expect(throws: CancellationError.self) {
            try verifier.verify(model, in: folder.root, onBytes: { bytes in
                reported.append(bytes)
                // The first block of the second file is hashed: stop now.
                if bytes > Int64(one.count) { stop = true }
            }, cancelled: { stop })
        }
        #expect(reported.last == Int64(one.count) + 128 * 1024, "stopped after the first block of two.bin")
        #expect(!verifier.isChecked(model, in: folder.root))
        #expect(model.ready(in: folder.root), "a stopped check removes nothing")
    }

    /// A file that cannot be read is no proof of a damaged model: the check fails and removes nothing.
    @Test func anUnreadableFileRemovesNothing() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        _ = try installed(folder.root)
        let verifier = ModelVerifier { _, _, _ in throw POSIXError(.EIO) }
        #expect(throws: POSIXError.self) { try verifier.verify(model, in: folder.root) }
        #expect(model.ready(in: folder.root))
        #expect(!verifier.isChecked(model, in: folder.root))
    }
}
