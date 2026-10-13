import Foundation

public struct TranscriptVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var portableID: String?
    public var createdAt: Date = Date()
    public var segments: [TranscriptSegment]
    public var speakers: [NoteSpeaker]
    /// The speaker aliases (`source -> target`) of the merge that made this version; an export writes them as
    /// `x-speakerMerges`, as Android records a merged variant.
    public var speakerMerges: [String: String]?
    /// The version a merge made this one from (`x-derivedFromTranscript` in an export).
    public var derivedFrom: UUID?
    public init(name: String, segments: [TranscriptSegment], speakers: [NoteSpeaker]) {
        self.name = name; self.segments = segments; self.speakers = speakers
    }
}
