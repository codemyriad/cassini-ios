import Foundation

public enum TranscriptFormat: String, CaseIterable, Identifiable, Sendable {
    case text = "txt", subtitles = "srt", webVTT = "vtt", json = "json"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .text: "Plain text"; case .subtitles: "Subtitles · SRT"; case .webVTT: "Subtitles · WebVTT"; case .json: "Timed transcript · JSON" }
    }
    public func data(for note: Note) throws -> Data {
        if self == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            var copy = note
            func publicSpeakers(_ speakers: [NoteSpeaker]) -> [NoteSpeaker] {
                speakers.map { value in var s = value; s.voiceID = nil; s.suggestedVoiceID = nil; s.excludedVoiceIDs = []; return s }
            }
            copy.speakers = publicSpeakers(copy.speakers ?? [])
            copy.versions = copy.versions?.map { value in var version = value; version.speakers = publicSpeakers(version.speakers); return version }
            return try encoder.encode(copy)
        }
        let content: String
        switch self {
        case .text:
            content = note.title + "\n\n" + note.transcript.map {
                "[\(TimeText.clock($0.start))] " + ($0.speaker.map { "\($0): " } ?? "") + $0.text
            }.joined(separator: "\n\n") + "\n"
        case .subtitles, .webVTT:
            let separator = self == .webVTT ? "." : ","
            content = (self == .webVTT ? "WEBVTT\n\n" : "") + note.transcript.enumerated().map { index, segment in
                let label = segment.speaker.map { "\($0): " } ?? ""
                let text = (label + segment.text).replacingOccurrences(of: "\n\n", with: "\n")
                return "\(index + 1)\n\(TimeText.subtitle(segment.start, separator: separator)) --> \(TimeText.subtitle(max(segment.start + 0.001, segment.end), separator: separator))\n\(text)\n"
            }.joined(separator: "\n")
        case .json: fatalError("Handled above")
        }
        return Data(content.utf8)
    }
}
