import CassiniCore
import Foundation

/// The transcript exports of features.md section 6, and the iOS-only JSON.
public enum TranscriptFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case text = "txt", markdown = "md", subtitles = "srt", webVTT = "vtt", json = "json"

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

/// The localized lines a transcript export needs; the writers themselves hold no copy.
public struct ExportTexts: Sendable {
    /// The TXT subtitle line from the note's creation time, duration and number of speakers.
    public var subtitle: @Sendable (_ createdAt: Date, _ durationMs: Int64, _ speakers: Int) -> String
    /// Formats a known instant, a zone-less label, or no date without inventing a meeting time.
    public var meetingSubtitle: (@Sendable (MeetingTime, Int64, Int) -> String)?
    /// The TXT body of a transcript without words.
    public var emptyText: String
    /// The label of passages without a speaker.
    public var unassignedLabel: String
    public var markdown: MarkdownOptions?

    public init(subtitle: @escaping @Sendable (Date, Int64, Int) -> String, emptyText: String, unassignedLabel: String,
                meetingSubtitle: (@Sendable (MeetingTime, Int64, Int) -> String)? = nil,
                markdown: MarkdownOptions? = nil) {
        self.subtitle = subtitle; self.emptyText = emptyText; self.unassignedLabel = unassignedLabel
        self.meetingSubtitle = meetingSubtitle
        self.markdown = markdown
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
                            texts: ExportTexts, markdownNotes: [MarkdownNote] = []) throws -> Data {
        var transcript = ExportTranscript(note: note, version: version, unassignedLabel: texts.unassignedLabel)
        let text: String
        switch format {
        case .markdown:
            guard let options = texts.markdown else { throw MarkdownExport.OptionsRequired() }
            var seen = Set<String>()
            let speakers = transcript.words.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
            for (index, speaker) in speakers.enumerated() {
                let label = transcript.labels[speaker]
                if label.flatMap(DefaultLabels.placeholderNumber) == nil,
                   label.map({ DefaultLabels.isDefault(id: speaker, label: $0) }) ?? true {
                    transcript.labels[speaker] = options.unnamedSpeaker(index + 1)
                }
            }
            text = MarkdownExport.write(transcript, dateLine: options.dateLine(note.meetingTime, transcript.durationMs),
                                        copy: options.copy, notes: markdownNotes)
        case .json: return try JSONExport.data(note, version: version)
        case .subtitles: text = SrtWriter.write(transcript)
        case .webVTT: text = VttWriter.write(transcript)
        case .text:
            // Android counts the selected variant's distinct word speakers, the count that also labels the turns.
            let subtitle: String
            if let render = texts.meetingSubtitle {
                subtitle = render(note.meetingTime, transcript.durationMs, transcript.speakerCount)
            } else if let instant = note.meetingTime.instant {
                subtitle = texts.subtitle(instant, transcript.durationMs, transcript.speakerCount)
            } else {
                subtitle = [note.meetingTime.localText, ExportClock.clock(transcript.durationMs, durationMs: transcript.durationMs)]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            text = TextExport.write(transcript, subtitle: subtitle, emptyText: texts.emptyText)
        }
        return Data(text.utf8)
    }

}
