import Foundation
import Testing
@testable import CassiniNotebook

struct SweepTests {
    private let base: URL
    private let notes: URL
    private let exports: URL
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    init() throws {
        base = try PortableFixtures.temporaryDirectory()
        notes = base.appendingPathComponent("Notes", isDirectory: true)
        exports = base.appendingPathComponent("tmp/Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    }

    /// Writes `url` (and its folder) with a modification date of `at`.
    @discardableResult
    private func file(_ url: URL, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data("x".utf8).write(to: url) }
        try touch(url, at: date)
        return url
    }

    private func touch(_ url: URL, at date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // ports: DocumentRepositoryTest#theSweepKeepsAudioAndRemovesStaleTmpFiles
    @Test func theSweepKeepsAudioAndRemovesStaleTmpFiles() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let a = UUID(), orphan = UUID(), lost = UUID()
        let dir = notes.appendingPathComponent(a.uuidString, isDirectory: true)
        let old = now.addingTimeInterval(-2 * 60 * 60)
        let capture = try file(dir.appendingPathComponent("capture.caf"), at: old)
        let note = try file(dir.appendingPathComponent(NoteRepository.metadataFilename), at: old)
        let staleTmp = try file(dir.appendingPathComponent("checkpoint.json.tmp"), at: old)
        let freshTmp = try file(dir.appendingPathComponent("source.tmp"), at: now)
        let work = dir.appendingPathComponent("work", isDirectory: true)
        let sealed = try file(work.appendingPathComponent("sealed.opus"), at: old)
        let workTmp = try file(work.appendingPathComponent("names.json.tmp"), at: old)
        let orphanDir = notes.appendingPathComponent(orphan.uuidString, isDirectory: true)
        try file(orphanDir.appendingPathComponent("source.tmp"), at: old)
        try touch(orphanDir, at: old)
        let lostDir = notes.appendingPathComponent(lost.uuidString, isDirectory: true)
        let orphanAudio = try file(lostDir.appendingPathComponent("capture.m4a"), at: old)
        try touch(lostDir, at: old)
        try file(exports.appendingPathComponent("\(UUID().uuidString)/left.txt"), at: old)

        let report = Sweep(notes: notes, exports: exports).run(known: [a], now: now)

        #expect(exists(capture) && exists(note))
        #expect(!exists(staleTmp))
        #expect(exists(freshTmp))
        #expect(exists(sealed))
        #expect(exists(workTmp))
        #expect(!exists(orphanDir))
        #expect(exists(orphanAudio))
        #expect(!exists(exports))
        #expect(report.deleted.count == 3)
    }

    @Test func aRecentOrphanFolderAndOtherFilesAreKept() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let old = now.addingTimeInterval(-2 * 60 * 60)
        // An import still copying into its staging file.
        let importing = notes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = try file(importing.appendingPathComponent("source.tmp"), at: now)
        try touch(importing, at: old)
        // A folder made a moment ago, before anything was written into it.
        let created = notes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // A note whose note.json could not be read: its files stay for the user.
        let unreadable = notes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let damaged = try file(unreadable.appendingPathComponent(NoteRepository.metadataFilename), at: old)
        try touch(unreadable, at: old)
        let jobs = try file(notes.appendingPathComponent("jobs.json.tmp"), at: old)

        let report = Sweep(notes: notes, exports: exports).run(known: [], now: now)

        #expect(report.deleted.isEmpty)
        #expect(exists(staging))
        #expect(exists(created))
        #expect(exists(damaged))
        #expect(exists(jobs))
    }
}
