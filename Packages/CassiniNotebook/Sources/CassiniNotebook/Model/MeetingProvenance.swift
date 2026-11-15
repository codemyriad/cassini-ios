import Foundation

/// Display-only provenance, derived from the existing import record without changing persisted notes.
public enum MeetingProvenance: Hashable, Sendable {
    case own, imported, importedOtherDevice

    public static func of(_ note: Note) -> Self {
        switch note.origin {
        // Recovery seals a recording made here; it is not an import.
        case .recorded, .recovered: return .own
        case .imported: return .imported
        case .importedDocument:
            // Kept imported versions survive local re-transcription, edits and speaker changes.
            let broughtTranscript = note.versions?.contains { $0.kind == .imported || $0.portableID != nil }
                ?? !note.transcript.isEmpty
            return broughtTranscript ? .importedOtherDevice : .imported
        }
    }

    public var subtitleKey: String? {
        switch self {
        case .own: nil
        case .imported: "format.previewSubtitle.received"
        case .importedOtherDevice: "format.previewSubtitle.importedOtherDevice"
        }
    }
}

extension NoteSubtitle {
    /// Unknown and timezone-free meeting times must not acquire the import date or an invented clock.
    public func importedText(template: String, day: String, time: String, duration: String) -> String {
        let dated: String
        switch meetingTime {
        case .instant: dated = template.replacingOccurrences(of: "{day}", with: day).replacingOccurrences(of: "{time}", with: time)
        case .local(let local): dated = template.replacingOccurrences(of: "{day}, {time}", with: local)
        case .unknown: dated = template.replacingOccurrences(of: "{day}, {time} · ", with: "")
        }
        return dated.replacingOccurrences(of: "{duration}", with: duration)
    }
}
