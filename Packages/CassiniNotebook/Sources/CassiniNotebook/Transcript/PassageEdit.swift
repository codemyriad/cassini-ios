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
    /// The name of the version a passage edit keeps of the transcript before it, when no kept version holds it.
    public static let beforePassageEditName = "Before passage edit"
    /// The name of the version that holds a run of passage edits.
    public static let editedVersionName = "Edited passages"

    /// Whether the transcript still holds `original` as it was.
    public func holds(_ original: TranscriptSegment) -> Bool { transcript.contains(original) }

    /// Replaces `original` with `revised` when the transcript still holds it unchanged.
    ///
    /// A run of edits keeps one version: the first edit keeps the transcript before it (unless a kept version holds it
    /// already) and adds an "Edited passages" version, which is then shown; later edits change that version in place,
    /// so twenty typo fixes add one copy of the transcript, not twenty. Both versions are stamped, so a rerun keeps the
    /// same ones. The edited version keeps the merge of the version it was made from (`saveCurrentVersion`).
    @discardableResult
    public mutating func revisePassage(_ original: TranscriptSegment, to revised: TranscriptSegment,
                                       stamp: VersionStamp) -> PassageEdit {
        guard revised != original else { return .unchanged }
        guard let index = transcript.firstIndex(of: original) else { return .changed }
        if let edited = shownEditedVersionIndex {
            transcript[index] = revised
            versions?[edited].segments = transcript
            return .saved
        }
        saveCurrentVersion(name: Self.beforePassageEditName, id: stamp.before, date: stamp.date)
        let base = selectedVersionID
        transcript[index] = revised
        selectedVersionID = nil
        saveCurrentVersion(name: Self.editedVersionName, id: stamp.after, date: stamp.date, editedFrom: base)
        return .saved
    }

    /// The index of the shown version when it is a run of passage edits that holds the transcript as it is. Naming
    /// and matching speakers keep it holding the transcript (see `changeShownSpeakers`), so they do not end the run.
    private var shownEditedVersionIndex: Int? {
        guard let index = shownVersionIndex, versions?[index].name == Self.editedVersionName else { return nil }
        return index
    }
}
