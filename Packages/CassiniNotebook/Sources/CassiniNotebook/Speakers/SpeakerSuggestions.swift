import Foundation

/// "Is this Luca?" above a speaker's first passage: a placeholder speaker that a saved voice may be.
public struct SpeakerSuggestion: Hashable, Sendable {
    public var speakerID: String
    public var label: String
    public var voiceID: UUID
    public var voiceName: String
    public var score: Float
    /// The passage the card goes above.
    public var segmentID: UUID
    public var start: Double

    public init(speakerID: String, label: String, voiceID: UUID, voiceName: String, score: Float, segmentID: UUID,
                start: Double) {
        self.speakerID = speakerID; self.label = label; self.voiceID = voiceID; self.voiceName = voiceName
        self.score = score; self.segmentID = segmentID; self.start = start
    }
}

public enum SpeakerSuggestions {
    /// The cards of `note`, in time order: one per speaker still called "Speaker N" whose match is a suggestion of a
    /// saved voice that exists and that the user did not reject for it.
    public static func of(_ note: Note, voices: [SavedVoice]) -> [SpeakerSuggestion] {
        let names = Dictionary(voices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return (note.speakers ?? []).compactMap { speaker -> SpeakerSuggestion? in
            guard case .suggested(let voice, let score) = speaker.match, let name = names[voice],
                  !speaker.excludedVoiceIDs.contains(voice), DefaultLabels.isDefault(id: speaker.id, label: speaker.name),
                  let first = note.transcript.first(where: { $0.speakerID == speaker.id }) else { return nil }
            return SpeakerSuggestion(speakerID: speaker.id, label: speaker.name, voiceID: voice, voiceName: name,
                                     score: score, segmentID: first.id, start: first.start)
        }.sorted { ($0.start, $0.speakerID) < ($1.start, $1.speakerID) }
    }
}
