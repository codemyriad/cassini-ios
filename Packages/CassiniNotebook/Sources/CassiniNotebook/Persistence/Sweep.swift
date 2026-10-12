import Foundation

/// The launch sweep (architecture 4.8, item 6): what a crash or a closed share sheet left behind.
///
/// It deletes the exports folder, `*.tmp` files older than an hour directly inside a note directory, and a note
/// directory without a note that holds nothing but such files and is older than an hour. It never deletes audio and
/// never looks inside a note's subfolders (`work/`).
public struct Sweep: Sendable {
    /// A `*.tmp` file this old belongs to no running write.
    public static let staleTmp: TimeInterval = 60 * 60
    public static let tmpSuffix = ".tmp"

    /// What one sweep deleted.
    public struct Report: Equatable, Sendable {
        public var deleted: [URL] = []
        public init(deleted: [URL] = []) { self.deleted = deleted }
    }

    /// The note directories, `<notes>/<uuid>/`.
    public let notes: URL
    /// The folder exports are made in for the share sheet.
    public let exports: URL

    public init(notes: URL, exports: URL) { self.notes = notes; self.exports = exports }

    /// Sweeps once. `known` are the ids of the notes that exist, readable or not; their directories are never
    /// removed. Files that cannot be read or deleted are left as they are.
    public func run(known: Set<UUID>, now: Date) -> Report {
        let files = FileManager.default
        var report = Report()
        if files.fileExists(atPath: exports.path), (try? files.removeItem(at: exports)) != nil {
            report.deleted.append(exports)
        }
        let cutoff = now.addingTimeInterval(-Self.staleTmp)
        let directories = (try? files.contentsOfDirectory(at: notes, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), Self.isDirectory(directory) else { continue }
            report.deleted += sweepNote(directory, isKnown: known.contains(id), cutoff: cutoff)
        }
        return report
    }

    private func sweepNote(_ directory: URL, isKnown: Bool, cutoff: Date) -> [URL] {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let entries = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        let staleTmp = entries.filter { entry in
            guard entry.lastPathComponent.hasSuffix(Self.tmpSuffix),
                  let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return false }
            return modified < cutoff
        }
        if !isKnown && staleTmp.count == entries.count && Self.modified(directory).map({ $0 < cutoff }) == true {
            return (try? files.removeItem(at: directory)) != nil ? [directory] : []
        }
        return staleTmp.filter { (try? files.removeItem(at: $0)) != nil }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
