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
    public var speakerID: String?
    public var words: [TimedWord]
    public init(id: UUID = UUID(), text: String, start: Double, end: Double, speaker: String? = nil, speakerID: String? = nil, words: [TimedWord] = []) {
        self.id = id; self.text = text; self.start = max(0, start); self.end = max(start, end)
        self.speaker = speaker; self.speakerID = speakerID; self.words = words
    }
}
