import Foundation

public struct TimedWord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public var lowConfidenceSpeaker: Bool?
    public init(id: UUID = UUID(), text: String, start: Double, end: Double, lowConfidenceSpeaker: Bool? = nil) {
        self.id = id; self.text = text; self.start = max(0, start); self.end = max(start, end)
        self.lowConfidenceSpeaker = lowConfidenceSpeaker
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
    /// Only a literal imported provenance marker vouches for authoritative measured word ends.
    /// Nil preserves compatibility with notes stored before the marker was retained.
    public var wordEndsBoundedByAudio: Bool?
    public init(id: UUID = UUID(), text: String, start: Double, end: Double, speaker: String? = nil, speakerID: String? = nil,
                words: [TimedWord] = [], wordEndsBoundedByAudio: Bool? = nil) {
        self.id = id; self.text = text; self.start = max(0, start); self.end = max(start, end)
        self.speaker = speaker; self.speakerID = speakerID; self.words = words
        self.wordEndsBoundedByAudio = wordEndsBoundedByAudio
    }
}
