import Foundation

/// The coarse state written by schema 1 and still written for older readers. New code derives what a row shows from the
/// job, the audio and the document instead.
public enum NoteStatus: String, Codable, Sendable {
    case recording, audioOnly, queued, transcribing, ready, failed
}

/// Whether the note's audio file can be played. Persisted with its case names: never rename one.
public enum AudioState: Codable, Hashable, Sendable {
    /// A capture is writing the file.
    case live
    case plain
    case unplayable(UnplayableReason)

    public var isPlayable: Bool { self == .plain }
}

public enum UnplayableReason: String, Codable, Hashable, Sendable {
    /// Cassini closed before the recording was saved.
    case interrupted
    /// This device cannot decode the file, e.g. an imported Opus container.
    case unsupportedFormat
}

/// How a note came to be. Persisted by raw value: never rename one.
public enum NoteOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case recorded, imported, importedDocument, recovered
}
