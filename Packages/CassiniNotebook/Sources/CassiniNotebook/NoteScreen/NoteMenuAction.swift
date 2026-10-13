import Foundation

/// What a row of the note's "…" menu asks the Note screen to do (`NoteScreenState.menu`).
public enum NoteMenuAction: Hashable, Sendable {
    case toggleStar, speakers, versions, rename, documentInfo
    case exportTranscript(TranscriptFormat)
    case exportDocument, shareAudio
    case transcribe, transcribeAgain, stop, removeFromQueue, resume, startOver
    case moveToTrash
}
