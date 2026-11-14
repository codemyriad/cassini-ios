import Foundation

/// A sheet over the Note screen. Kept with the scene as its `NoteOverlay`, so it opens again when the screen comes
/// back after Cassini was closed.
public enum NoteSheet: Identifiable, Hashable, Sendable {
    /// Rename, starting from `draft` when one was being typed before Cassini was closed.
    case rename(draft: String?)
    case speakers, versions, documentInfo
    /// Name this speaker, starting from `draft` when one was being typed before Cassini was closed.
    case naming(String, draft: String?)
    /// Edit passage, of the passage as it was when the editor opened.
    case editing(TranscriptSegment)

    public var id: String {
        switch self {
        case .rename: "rename"
        case .speakers: "speakers"
        case .versions: "versions"
        case .documentInfo: "documentInfo"
        case .naming(let id, _): "naming-\(Data(id.utf8).base64EncodedString())"
        case .editing(let segment): "editing-\(segment.id)"
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.rename(let a), .rename(let b)): a == b
        case (.speakers, .speakers), (.versions, .versions), (.documentInfo, .documentInfo): true
        case (.naming(let a, let firstDraft), .naming(let b, let secondDraft)):
            Data(a.utf8) == Data(b.utf8) && firstDraft == secondDraft
        case (.editing(let a), .editing(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .rename(let draft): hasher.combine(0); hasher.combine(draft)
        case .speakers: hasher.combine(1)
        case .versions: hasher.combine(2)
        case .documentInfo: hasher.combine(3)
        case .naming(let id, let draft): hasher.combine(4); hasher.combine(Data(id.utf8)); hasher.combine(draft)
        case .editing(let segment): hasher.combine(5); hasher.combine(segment)
        }
    }

    public var overlay: NoteOverlay {
        switch self {
        case .rename: .rename
        case .speakers: .speakers
        case .versions: .versions
        case .documentInfo: .documentInfo
        case .naming(let id, _): .naming(speakerID: id)
        case .editing(let segment): .editing(segmentID: segment.id)
        }
    }

    /// The sheet of a kept `overlay`; nil for a passage the note no longer has.
    public init?(_ overlay: NoteOverlay, draft: String?, in note: Note) {
        switch overlay {
        case .rename: self = .rename(draft: draft)
        case .speakers: self = .speakers
        case .versions: self = .versions
        case .documentInfo: self = .documentInfo
        case .naming(let id): self = .naming(id, draft: draft)
        case .editing(let id):
            guard let segment = note.transcript.first(where: { $0.id == id }) else { return nil }
            self = .editing(segment)
        }
    }

    /// The sheet `effect` opens, fresh; nil for an effect that opens none, or a passage `note` no longer has.
    public init?(opening effect: NoteEffect, in note: Note?) {
        switch effect {
        case .nameSpeaker(let id): self = .naming(id, draft: nil)
        case .openVersions: self = .versions
        case .openSpeakers: self = .speakers
        case .rename: self = .rename(draft: nil)
        case .documentInfo: self = .documentInfo
        case .editPassage(let id):
            guard let segment = note?.transcript.first(where: { $0.id == id }) else { return nil }
            self = .editing(segment)
        case .seekAndPlay, .transcribe, .startOver, .acknowledgeTrustAndPlay, .continueQueue, .clearFailed, .toggleStar,
             .exportTranscript, .exportDocument, .shareAudio, .stop, .removeFromQueue, .moveToTrash:
            return nil
        }
    }

    public var draft: String? {
        switch self {
        case .naming(_, let draft), .rename(let draft): draft
        case .speakers, .versions, .documentInfo, .editing: nil
        }
    }
}
