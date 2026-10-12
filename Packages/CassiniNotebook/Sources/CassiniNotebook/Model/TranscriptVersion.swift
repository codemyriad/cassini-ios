import Foundation

public struct TranscriptVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var portableID: String?
    public var createdAt: Date = Date()
    public var segments: [TranscriptSegment]
    public var speakers: [NoteSpeaker]
    public init(name: String, segments: [TranscriptSegment], speakers: [NoteSpeaker]) {
        self.name = name; self.segments = segments; self.speakers = speakers
    }
}
