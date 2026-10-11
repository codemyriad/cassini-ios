import Foundation

public struct TimedWord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public init(id: UUID = UUID(), text: String, start: Double, end: Double) {
        self.id = id; self.text = text; self.start = max(0, start); self.end = max(start, end)
    }
}

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var words: [TimedWord]
    public init(id: UUID = UUID(), text: String, start: Double, end: Double, speaker: String? = nil, words: [TimedWord] = []) {
        self.id = id; self.text = text; self.start = max(0, start); self.end = max(start, end)
        self.speaker = speaker; self.words = words
    }
}

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String
    public init(id: UUID = UUID(), time: Double, label: String = "Marked moment") {
        self.id = id; self.time = max(0, time); self.label = label
    }
}

public enum NoteStatus: String, Codable, Sendable {
    case recording, audioOnly, queued, transcribing, ready, failed
    public var label: String {
        switch self {
        case .recording: "Recording"
        case .audioOnly: "Audio only"
        case .queued: "Queued"
        case .transcribing: "Transcribing"
        case .ready: "Transcribed"
        case .failed: "Needs attention"
        }
    }
}

public struct Note: Codable, Identifiable, Hashable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var audioFilename: String
    public var duration: Double = 0
    public var status: NoteStatus = .audioOnly
    public var transcript: [TranscriptSegment] = []
    public var bookmarks: [Bookmark] = []
    public var waveform: [Float] = []
    public var isFavorite = false
    public var trashedAt: Date?
    public var playbackPosition: Double = 0
    public var language: String = Locale.current.identifier
    public var failureMessage: String?
    public var playbackUnavailable: String?
    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), audioFilename: String = "audio.m4a") {
        self.id = id; self.title = title; self.createdAt = createdAt; self.audioFilename = audioFilename
    }
    public var text: String { transcript.map(\.text).joined(separator: " ") }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    public func matches(_ query: String) -> Bool {
        let haystack = (title + " " + text + " " + bookmarks.map(\.label).joined(separator: " "))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { haystack.contains($0) }
    }
    public func preview(matching query: String) -> String {
        let body = text
        guard let term = query.split(whereSeparator: \.isWhitespace).first,
              let match = body.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(body.prefix(180))
        }
        let start = body.index(match.lowerBound, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
        return (start == body.startIndex ? "" : "…") + String(body[start...].prefix(180))
    }
}

public enum TimeText {
    public static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func subtitle(_ seconds: Double, separator: String = ",") -> String {
        let ms = seconds.isFinite ? Int((max(0, seconds) * 1000).rounded()) : 0
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
