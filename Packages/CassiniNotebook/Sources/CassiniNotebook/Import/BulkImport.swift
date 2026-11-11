import Foundation
import CassiniCore

public struct TransferProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

public struct ImportSummary: Equatable, Sendable {
    public var imported = 0
    public var duplicates = 0
    public var unsupported = 0
    public var failed = 0
    public init() {}
    public mutating func add(_ outcome: ImportOutcome) {
        switch outcome { case .created: imported += 1; case .existing: duplicates += 1; case .rejected: failed += 1 }
    }
}

public struct BulkImportReport: Sendable {
    public var summary = ImportSummary()
    public var cancelled = false
    public var archives: [ZIPFailure] = []
    public init() {}
}

public enum ArchiveAudio {
    /// Containers offered by iOS's audio picker; AVFoundation/the existing importer still verifies their bytes.
    public static let extensions: Set<String> = ["opus", "ogg", "oga", "wav", "mp3", "m4a", "m4b", "aac", "flac",
                                                  "aif", "aiff", "caf", "mp4", "3gp", "3gpp", "3g2", "amr", "ac3", "au", "sd2"]
    public static func supports(_ name: String) -> Bool { extensions.contains((name as NSString).pathExtension.lowercased()) }
}

public enum ArchiveContents {
    public static func preservesOriginal(_ note: Note) -> Bool {
        if let state = note.document?.state, state == .unknownFormat || state == .unreadable || state == .invalidMetadata { return true }
        return note.document == nil && note.transcript.isEmpty && !(note.versions?.contains { !$0.segments.isEmpty } ?? false)
    }
}

/// The existing export naming rule, with collision handling shared with Android. Comparisons are case-insensitive
/// so an archive also extracts safely on case-insensitive volumes.
public struct ArchiveNames: Sendable {
    private var used: Set<String> = []
    private var nextSuffix: [String: Int] = [:]
    public init() {}
    public mutating func next(title: String, extension ext: String) -> String {
        let stem = ExportNames.stem(title)
        let suffix = ext.isEmpty ? "" : "." + ext
        var name = stem + suffix
        let key = name.lowercased()
        if used.insert(key).inserted { nextSuffix[key] = 2; return name }
        var n = nextSuffix[key] ?? 2
        repeat { name = stem + " (\(n))" + suffix; n += 1 } while !used.insert(name.lowercased()).inserted
        nextSuffix[key] = n
        return name
    }
}
