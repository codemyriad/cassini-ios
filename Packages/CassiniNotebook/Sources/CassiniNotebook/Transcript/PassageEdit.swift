import Foundation

extension TranscriptSegment {
    /// The passage with new `text` (trimmed) and speaker. A text that changed loses its word times, since they no
    /// longer match its words; the passage then plays and highlights as one piece. The speaker's label is taken from
    /// `speakers`; nil or an unknown id leaves the passage without a speaker.
    public func revised(text: String, speakerID: String?, speakers: [NoteSpeaker]) -> TranscriptSegment {
        var revised = self
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != self.text {
            revised.text = trimmed
            revised.words = []
        }
        let speaker = speakerID.flatMap { id in speakers.first { $0.id == id } }
        revised.speakerID = speaker?.id
        revised.speaker = speaker?.name
        return revised
    }

    /// The edit can be saved: its text is not blank.
    public static func isSavable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What saving an edited passage did.
public enum PassageEdit: Hashable, Sendable {
    case saved
    /// The passage is no longer in the transcript as it was when the edit began (another version is shown, a job or
    /// another edit changed it): "This passage changed while you were editing."
    case changed
    case unchanged
}

extension Note {
    /// The name of the version a passage edit keeps of the transcript before it.
    public static let beforePassageEditName = "Before passage edit"

    /// Whether the transcript still holds `original` as it was.
    public func holds(_ original: TranscriptSegment) -> Bool { transcript.contains(original) }

    /// Replaces `original` with `revised` when the transcript still holds it unchanged, keeping the transcript before as
    /// a version (stamped, so a rerun keeps the same one). The edited transcript is not a kept version until it changes
    /// again.
    @discardableResult
    public mutating func revisePassage(_ original: TranscriptSegment, to revised: TranscriptSegment,
                                       stamp: VersionStamp) -> PassageEdit {
        guard revised != original else { return .unchanged }
        guard let index = transcript.firstIndex(of: original) else { return .changed }
        saveCurrentVersion(name: Self.beforePassageEditName, id: stamp.before, date: stamp.date)
        transcript[index] = revised
        selectedVersionID = nil
        return .saved
    }
}
