import Foundation

/// How an import ended (Android `ImportOutcome`). A rejected import left nothing behind.
public enum ImportOutcome: Hashable, Sendable {
    /// A new note.
    case created(UUID)
    /// A live note already has these bytes; nothing was added.
    case existing(UUID)
    case rejected(ImportFailureKind)

    /// The note the import leads to: the new one or the one that was already there.
    public var noteID: UUID? {
        switch self {
        case .created(let id), .existing(let id): id
        case .rejected: nil
        }
    }

    public var failure: ImportFailureKind? {
        if case .rejected(let kind) = self { kind } else { nil }
    }
}

/// The audio an import found, as the note keeps it.
public struct ImportedAudio: Hashable, Sendable {
    /// The file the note plays.
    public var filename: String
    /// The file as imported, when the note plays a decoded copy of it.
    public var originalFilename: String?
    public var duration: TimeInterval
    public var waveform: [Float]
    public var state: AudioState

    public init(filename: String, originalFilename: String? = nil, duration: TimeInterval, waveform: [Float] = [],
                state: AudioState = .plain) {
        self.filename = filename; self.originalFilename = originalFilename; self.duration = duration
        self.waveform = waveform; self.state = state
    }
}

/// Builds the note of an import (Android `ImportRepository.insert` and `DocumentRepository.catalogueDocument`).
public enum ImportedNote {
    public static func make(id: UUID, displayName: String?, fallbackTitle: String, sha256: String, importedAt: Date,
                            audio: ImportedAudio, document: PortableTranscript? = nil) -> Note {
        var note = Note(id: id, title: ImportTitles.title(displayName: displayName, fallback: fallbackTitle),
                        createdAt: importedAt, audioFilename: audio.filename)
        note.originalAudioFilename = audio.originalFilename
        note.duration = audio.duration
        note.waveform = audio.waveform
        note.audio = audio.state
        note.meetingTime = .unknown
        note.origin = .imported
        note.sourceSha256 = sha256
        guard let document else { return note }
        note.origin = .importedDocument
        note.document = document.info
        note.meetingTime = document.meetingTime
        if let title = NoteTitles.fit(document.title) { note.title = title }
        if let createdAt = document.createdAt { note.createdAt = createdAt }
        if let duration = document.duration { note.duration = duration }
        if document.hasTranscript {
            note.language = document.language
            note.transcript = document.segments
            note.speakers = document.speakers
            note.versions = document.versions
            note.selectedVersionID = document.selectedVersionID
            note.status = .ready
        }
        return note
    }

    /// Whether a just imported note may be queued for transcription on its own: never when it brought a transcript
    /// it can show, nor for a document in a newer format, nor when its audio does not play.
    public static func wantsTranscription(_ note: Note) -> Bool {
        note.transcript.isEmpty && note.audio.isPlayable && note.document?.state != .unknownFormat
    }
}
