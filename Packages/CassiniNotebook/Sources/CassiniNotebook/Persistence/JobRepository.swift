import Foundation

/// The transcription queue on disk: `<root>/jobs.json`, every job in `seq` order, written atomically.
public struct JobRepository: Sendable {
    public static let filename = "jobs.json"
    public static let version = 1

    public enum Failure: Error, Equatable {
        /// The file was written by a newer version of Cassini.
        case unsupportedVersion(Int)
    }

    private struct Header: Decodable {
        var version: Int
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
        let data = try Data(contentsOf: url)
        // The version first: a newer file may hold jobs this build cannot decode.
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.version <= Self.version else { throw Failure.unsupportedVersion(header.version) }
        return try JSONDecoder().decode(File.self, from: data).jobs.sorted { $0.seq < $1.seq }
    }

    /// Moves an unreadable `jobs.json` to `jobs.json.unreadable-<stamp>` beside it, so a new queue never overwrites
    /// it. Returns where it went.
    @discardableResult
    public func moveAside(at stamp: Date) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "\(Self.filename).unreadable-\(formatter.string(from: stamp))"
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(version: Self.version, jobs: jobs.sorted { $0.seq < $1.seq })).write(to: url, options: .atomic)
    }
}
