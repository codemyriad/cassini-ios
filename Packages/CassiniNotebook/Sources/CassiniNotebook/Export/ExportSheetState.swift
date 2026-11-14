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

    public init(note: Note, jobPending: Bool = false) {
        let completed = note.status == .ready && !jobPending && TranscriptExports.availability(of: note) == .available
        let original = !completed && note.origin == .imported && note.document == nil
        let audio: Choice = original ? .originalAudio : .cassiniFile
        primary = completed ? [audio, .markdown] : [audio]
        moreFormats = completed ? [.plainText, .srt, .vtt] : []
        selection = audio
    }
    /// D12: draft words and local draft versions never travel in an audio-only Cassini file.
    public static func portableSnapshot(_ note: Note) -> Note {
        guard note.status != .ready else { return note }
        var snapshot = note
        snapshot.transcript = []
        snapshot.versions = []
        snapshot.selectedVersionID = nil
        return snapshot
    }

}
