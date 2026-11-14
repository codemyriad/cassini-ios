import Foundation

/// How a speaker in a note relates to a saved voice. Persisted with its case names: never rename one.
public enum VoiceMatchState: Codable, Hashable, Sendable {
    case unmatched
    /// Named automatically from a strong match; the user has not confirmed it.
    case auto(voice: UUID, score: Float)
    /// Offered as "Is this …?" without changing the name.
    case suggested(voice: UUID, score: Float)
    /// The user linked this speaker to the voice.
    case confirmed(voice: UUID, score: Float)
    /// The user said this speaker is not the voice; it is never offered again.
    case rejected(voice: UUID, score: Float)

    public var voiceID: UUID? {
        switch self {
        case .unmatched: nil
        case .auto(let voice, _), .suggested(let voice, _), .confirmed(let voice, _), .rejected(let voice, _): voice
        }
    }

    public var score: Float? {
        switch self {
        case .unmatched: nil
        case .auto(_, let score), .suggested(_, let score), .confirmed(_, let score), .rejected(_, let score): score
        }
    }

    public var isRejection: Bool {
        if case .rejected = self { true } else { false }
    }
}

public struct NoteSpeaker: Identifiable, Hashable, Sendable {
    public enum Provenance: String, Codable, Hashable, Sendable { case user, recognised, unnamed, source }
    /// Assigned once in all-speaker first-speech order, including unnamed speakers.
    public var colourIndex: Int?
    public var provenance: Provenance

    public var id: String
    public var byteID: Data { Data(id.utf8) }
    public var name: String {
        didSet {
            // Explicit provenance is authoritative, including a person's literal name "Speaker 2".
            if provenance == .unnamed, !DefaultLabels.isDefault(id: id, label: name) { provenance = .user }
        }
    }
    public var match: VoiceMatchState = .unmatched
    public var excludedVoiceIDs: [UUID] = []
    public init(id: String, name: String, match: VoiceMatchState = .unmatched,
                colourIndex: Int? = nil, provenance: Provenance? = nil) {
        self.id = id; self.name = name; self.match = match
        self.colourIndex = colourIndex
        self.provenance = provenance ?? (DefaultLabels.isDefault(id: id, label: name) ? .unnamed : .user)
    }

    /// The saved voice whose name this speaker carries: an automatic or a confirmed match.
    public var linkedVoiceID: UUID? {
        switch match {
        case .auto(let voice, _), .confirmed(let voice, _): voice
        default: nil
        }
    }

    /// The saved voice offered for review: a suggestion or an unconfirmed automatic match.
    public var suggestedVoiceID: UUID? {
        switch match {
        case .auto(let voice, _), .suggested(let voice, _): voice
        default: nil
        }
    }
}

extension NoteSpeaker: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, match, excludedVoiceIDs, colourIndex, provenance
        // Schema 1 kept the link and the suggestion as two optional ids.
        case voiceID, suggestedVoiceID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colourIndex = try container.decodeIfPresent(Int.self, forKey: .colourIndex)
        if let colourIndex, !(0...SpeakerColourAllocator.maximum).contains(colourIndex) {
            throw DecodingError.dataCorruptedError(forKey: .colourIndex, in: container,
                                                   debugDescription: "Invalid speaker colour index")
        }
        provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance)
            ?? (DefaultLabels.isDefault(id: id, label: name) ? .unnamed : .user)
        excludedVoiceIDs = try container.decodeIfPresent([UUID].self, forKey: .excludedVoiceIDs) ?? []
        if let match = try container.decodeIfPresent(VoiceMatchState.self, forKey: .match) {
            self.match = match
        } else {
            let linked = try container.decodeIfPresent(UUID.self, forKey: .voiceID)
            let suggested = try container.decodeIfPresent(UUID.self, forKey: .suggestedVoiceID)
            match = Self.legacyMatch(linked: linked, suggested: suggested)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(colourIndex, forKey: .colourIndex)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(match, forKey: .match)
        try container.encode(excludedVoiceIDs, forKey: .excludedVoiceIDs)
    }

    /// Schema 1 set both ids for an automatic name, only the link after the user saved one, and only the suggestion otherwise.
    static func legacyMatch(linked: UUID?, suggested: UUID?) -> VoiceMatchState {
        switch (linked, suggested) {
        case let (linked?, suggested?) where linked == suggested: .auto(voice: linked, score: 0)
        case let (linked?, _): .confirmed(voice: linked, score: 0)
        case let (nil, suggested?): .suggested(voice: suggested, score: 0)
        case (nil, nil): .unmatched
        }
    }
}
