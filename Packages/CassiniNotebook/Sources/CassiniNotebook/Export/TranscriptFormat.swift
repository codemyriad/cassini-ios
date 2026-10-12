import CassiniCore
import Foundation

/// The transcript exports of features.md section 6, and the iOS-only JSON.
public enum TranscriptFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case text = "txt", subtitles = "srt", webVTT = "vtt", json = "json"

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

/// The localized lines a transcript export needs; the writers themselves hold no copy.
public struct ExportTexts: Sendable {
    /// The TXT subtitle line from the note's creation time, duration and number of speakers.
    public var subtitle: @Sendable (_ createdAt: Date, _ durationMs: Int64, _ speakers: Int) -> String
    /// The TXT body of a transcript without words.
    public var emptyText: String
    /// The label of passages without a speaker.
    public var unassignedLabel: String

    public init(subtitle: @escaping @Sendable (Date, Int64, Int) -> String, emptyText: String, unassignedLabel: String) {
        self.subtitle = subtitle; self.emptyText = emptyText; self.unassignedLabel = unassignedLabel
    }
}

/// Whether a note's transcript can be exported, and why not.
public enum TranscriptExportAvailability: Hashable, Sendable {
    case available
    /// The note has no transcript yet: "Available after transcription".
    case afterTranscription
    /// The note is a document Cassini cannot read: "Not available for this transcript".
    case notReadable
}

public enum TranscriptExports {
    /// Document states whose transcript cannot be exported (features.md section 6, Android's `NOT_READABLE`).
    public static let notExportable: Set<DocumentState> = [.unreadable, .invalidMetadata, .unknownFormat]

    /// A note exports its transcript once it has one: a finished transcription (even one without words) or a
    /// transcript kept from before. A live capture and a document Cassini cannot read (`notExportable`) do not.
    public static func availability(of note: Note) -> TranscriptExportAvailability {
        if let state = note.document?.state, notExportable.contains(state) { return .notReadable }
        if note.isRecording || (note.transcript.isEmpty && note.status != .ready) { return .afterTranscription }
        return .available
    }

    /// The bytes of `note`'s transcript (or `version`'s) in `format`: UTF-8 without BOM, `\n` line endings.
    public static func data(_ note: Note, format: TranscriptFormat, version: TranscriptVersion? = nil,
                            texts: ExportTexts) throws -> Data {
        let transcript = ExportTranscript(note: note, version: version, unassignedLabel: texts.unassignedLabel)
        let text: String
        switch format {
        case .json: return try JSONExport.data(note, version: version)
        case .subtitles: text = SrtWriter.write(transcript)
        case .webVTT: text = VttWriter.write(transcript)
        case .text:
            let subtitle = texts.subtitle(note.createdAt, transcript.durationMs, speakerCount(note, version: version))
            text = TextExport.write(transcript, subtitle: subtitle, emptyText: texts.emptyText)
        }
        return Data(text.utf8)
    }

    /// The TXT subtitle line's number of speakers: the speakers of the exported transcript, as Android counts the
    /// selected variant's, so passages without a speaker add none and a speaker without words still counts.
    static func speakerCount(_ note: Note, version: TranscriptVersion?) -> Int {
        Set((version?.speakers ?? note.speakers ?? []).map(\.id)).count
    }
}
