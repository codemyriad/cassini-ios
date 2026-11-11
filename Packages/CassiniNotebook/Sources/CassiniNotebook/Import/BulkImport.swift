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
    /// A clean imported document is backed up as stored, even if its optional TITLE mirror is absent/stale.
    /// Compare portable content, not UUIDs assigned by the importer or Library-only fields such as bookmarks.
    public static func matchesImportedDocument(_ note: Note, _ document: PortableTranscript) -> Bool {
        guard note.document != nil, sameSegments(note.transcript, document.segments), sameSpeakers(note.speakers ?? [], document.speakers),
              note.language == document.language else { return false }
        if let title = NoteTitles.fit(document.title), note.title != title { return false }
        let versions = (note.versions ?? []).filter { !$0.segments.isEmpty }
        var originals: [String: TranscriptVersion] = [:]
        for version in document.versions where !version.segments.isEmpty {
            guard let id = version.portableID, originals.updateValue(version, forKey: id) == nil else { return false }
        }
        guard versions.count == originals.count else { return false }
        for version in versions {
            guard let id = version.portableID, let original = originals.removeValue(forKey: id),
                  sameSegments(version.segments, original.segments), sameSpeakers(version.speakers, original.speakers),
                  version.language == original.language else { return false }
        }
        let selected = note.versions?.first { $0.id == note.selectedVersionID }?.portableID
        return selected == document.selected?.portableID
    }

    private static func sameSegments(_ lhs: [TranscriptSegment], _ rhs: [TranscriptSegment]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            // Group/word UUIDs belong to the UI cache, not to the portable file.
            var normalized = left
            normalized.id = right.id
            guard normalized.words.count == right.words.count else { return false }
            for index in normalized.words.indices { normalized.words[index].id = right.words[index].id }
            return normalized == right
        }
    }
    private static func sameSpeakers(_ lhs: [NoteSpeaker], _ rhs: [NoteSpeaker]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.name == $1.name }
    }

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
