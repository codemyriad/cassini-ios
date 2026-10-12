import Foundation

/// The transcription queue on disk: `<root>/jobs.json`, every job in `seq` order, written atomically.
public struct JobRepository: Sendable {
    public static let filename = "jobs.json"
    public static let version = 1

    public enum Failure: Error, Equatable {
        /// The file was written by a newer version of Cassini.
        case unsupportedVersion(Int)
    }

    private struct File: Codable {
        var version: Int
        var jobs: [Job]
    }

    public let url: URL

    public init(root: URL) {
        url = root.appendingPathComponent(Self.filename)
    }

    /// The stored jobs in `seq` order; none when the file does not exist yet.
    public func load() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.version <= Self.version else { throw Failure.unsupportedVersion(file.version) }
        return file.jobs.sorted { $0.seq < $1.seq }
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(version: Self.version, jobs: jobs.sorted { $0.seq < $1.seq })).write(to: url, options: .atomic)
    }
}
