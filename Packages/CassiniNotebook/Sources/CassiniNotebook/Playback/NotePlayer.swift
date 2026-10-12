import Foundation

/// Whether a Note screen shows the player, and what its player follows (Android's `NoteMapping.hasPlayer` and the
/// Note screen's `PlayerKey`).
public enum NotePlayer {
    /// The note shows its player: playable audio that is not being transcribed.
    public static func hasPlayer(_ note: Note) -> Bool {
        note.audio.isPlayable && note.status != .transcribing
    }

    /// What the screen's player follows; nil while the note shows no player, or while a recording keeps the player
    /// closed (`blocked`, the same condition that closes it). A change of the key opens the player, reloads it or
    /// leaves it, so the player opens again as soon as the recording lets it go.
    public static func key(for note: Note?, blocked: Bool) -> Key? {
        guard let note, !blocked, hasPlayer(note) else { return nil }
        return Key(noteID: note.id, audioFilename: note.audioFilename, duration: note.duration)
    }

    /// The note's file as the player opens it. A recording's compressed copy has another name; the file's size and
    /// modification date are compared when the screen shows the player again, not here.
    public struct Key: Hashable, Sendable {
        public let noteID: UUID
        public let audioFilename: String
        public let duration: TimeInterval
    }
}
