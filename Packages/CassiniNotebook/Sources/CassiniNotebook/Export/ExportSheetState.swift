import Foundation

/// D99 single-meeting choices. JSON remains an internal writer, never a sheet option.
public struct ExportSheetState: Equatable, Sendable {
    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        case cassiniFile, markdown, plainText, srt, vtt, originalAudio
        public var id: String { rawValue }
        public var transcriptFormat: TranscriptFormat? {
            switch self {
            case .cassiniFile, .originalAudio: nil
            case .markdown: .markdown
            case .plainText: .text
            case .srt: .subtitles
            case .vtt: .webVTT
            }
        }
    }
    public let primary: [Choice]
    public let moreFormats: [Choice]
    public var audioOnly: Bool { moreFormats.isEmpty }
    public var selection: Choice

    // Pending jobs contain their own drafts and do not change availability of stored transcripts.
    public init(note: Note, jobPending _: Bool = false) {
        let completed = TranscriptExports.availability(of: note) == .available
        let original = !completed && note.origin == .imported && note.document == nil
        let audio: Choice = original ? .originalAudio : .cassiniFile
        primary = completed ? [audio, .markdown] : [audio]
        moreFormats = completed ? [.plainText, .srt, .vtt] : []
        selection = audio
    }
    /// D12: first-run jobs have no stored transcript; re-transcription keeps the completed one.
    public static func portableSnapshot(_ note: Note) -> Note {
        guard !note.hasFinishedTranscript else { return note }
        var snapshot = note
        snapshot.transcript = []
        snapshot.versions = []
        snapshot.selectedVersionID = nil
        return snapshot
    }

}
