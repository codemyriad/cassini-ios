import Foundation

/// A kept copy of a note's transcript and speakers.
public struct TranscriptVersion: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    /// What made the version; the screens name it in the reader's language.
    public var kind: TranscriptVersionKind
    public var portableID: String?
    public var createdAt: Date = Date()
    public var segments: [TranscriptSegment]
    public var speakers: [NoteSpeaker]
    public init(kind: TranscriptVersionKind, segments: [TranscriptSegment], speakers: [NoteSpeaker]) {
        self.kind = kind; self.segments = segments; self.speakers = speakers
    }
}

/// What made a transcript version. Stored as a code, never as display text: the Versions sheet names it.
public enum TranscriptVersionKind: Hashable, Sendable {
    /// A transcription on this device.
    case transcription
    /// The transcript shown before another version was selected or a new transcription replaced it.
    case previous
    case beforeSpeakerMerge
    case mergedSpeakers
    case beforeSpeakerAnalysis
    case speakerAnalysis
    case beforePassageEdit
    case editedPassages
    /// The transcript as it was when a Cassini document was exported.
    case editedTranscript
    /// A variant of an imported Cassini document (its id is the version's `portableID`).
    case imported
    /// A name an earlier build stored that is none of the above; shown as it is and written back as a name.
    case legacy(String)
    /// A code a newer build stored that this one does not know; written back as that code, so the newer build still
    /// reads the kind.
    case unknown(String)

    /// The stored codes; `legacy` stores its name instead.
    var code: String? {
        switch self {
        case .transcription: "transcription"
        case .previous: "previous"
        case .beforeSpeakerMerge: "beforeSpeakerMerge"
        case .mergedSpeakers: "mergedSpeakers"
        case .beforeSpeakerAnalysis: "beforeSpeakerAnalysis"
        case .speakerAnalysis: "speakerAnalysis"
        case .beforePassageEdit: "beforePassageEdit"
        case .editedPassages: "editedPassages"
        case .editedTranscript: "editedTranscript"
        case .imported: "imported"
        case .unknown(let code): code
        case .legacy: nil
        }
    }

    /// The English name earlier builds showed and stored for each kind. It is written beside the code so a note stays
    /// readable by a build from before kinds (which requires a name); this build reads the code.
    var legacyName: String {
        switch self {
        case .transcription: "On-device transcription"
        case .previous: "Previous transcript"
        case .beforeSpeakerMerge: "Before speaker merge"
        case .mergedSpeakers: "Merged speakers"
        case .beforeSpeakerAnalysis: "Before speaker analysis"
        case .speakerAnalysis: "Speaker analysis"
        case .beforePassageEdit: "Before passage edit"
        case .editedPassages: "Edited passages"
        case .editedTranscript: "Edited transcript"
        case .imported: "Imported"
        case .legacy(let name): name
        case .unknown(let code): code
        }
    }

    static let coded: [TranscriptVersionKind] = [.transcription, .previous, .beforeSpeakerMerge, .mergedSpeakers,
                                                 .beforeSpeakerAnalysis, .speakerAnalysis, .beforePassageEdit,
                                                 .editedPassages, .editedTranscript, .imported]

    init(code: String) { self = Self.coded.first { $0.code == code } ?? .unknown(code) }

    /// Earlier builds stored the English name each kind was shown with.
    init(legacyName name: String) {
        self = switch name {
        case "On-device transcription": .transcription
        case "Previous transcript": .previous
        case "Before speaker merge": .beforeSpeakerMerge
        case "Merged speakers": .mergedSpeakers
        case "Before speaker analysis": .beforeSpeakerAnalysis
        case "Speaker analysis": .speakerAnalysis
        case "Before passage edit": .beforePassageEdit
        case "Edited passages": .editedPassages
        case "Edited transcript": .editedTranscript
        case _ where name.hasPrefix("Imported"): .imported
        default: .legacy(name)
        }
    }
}

extension TranscriptVersion: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, name, portableID, createdAt, segments, speakers }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let code = try c.decodeIfPresent(String.self, forKey: .kind) {
            kind = TranscriptVersionKind(code: code)
        } else {
            kind = TranscriptVersionKind(legacyName: try c.decode(String.self, forKey: .name))
        }
        portableID = try c.decodeIfPresent(String.self, forKey: .portableID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        speakers = try c.decode([NoteSpeaker].self, forKey: .speakers)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(kind.code, forKey: .kind)
        try c.encode(kind.legacyName, forKey: .name)
        try c.encodeIfPresent(portableID, forKey: .portableID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(segments, forKey: .segments)
        try c.encode(speakers, forKey: .speakers)
    }
}
