import Foundation
import CassiniEngine

extension EnqueueRefusal {
    /// What a Transcribe that was refused tells the person, from the Transcription table.
    var message: String {
        switch self {
        case .noNote:
            String(localized: "This recording no longer exists.", table: "Transcription",
                   comment: "A Transcribe was refused: the note is gone")
        case .trashed:
            String(localized: "Restore this recording from Recently Deleted to transcribe it.", table: "Transcription",
                   comment: "A Transcribe was refused: the note is in Recently Deleted")
        case .recording:
            String(localized: "This recording is still being saved. Try again in a moment.", table: "Transcription",
                   comment: "A Transcribe was refused: the recording is still being written")
        case .unknownFormat:
            String(localized: "This recording was saved by a newer version of Cassini. Update Cassini to transcribe it.",
                   table: "Transcription", comment: "A Transcribe was refused: the note's format is newer")
        case .unplayable:
            String(localized: "Cassini can’t play this audio, so there is nothing to transcribe.", table: "Transcription",
                   comment: "A Transcribe was refused: the audio cannot be decoded")
        case .queueUnavailable:
            String(localized: "The transcription queue was saved by a newer version of Cassini, or can’t be read. Update Cassini to transcribe.",
                   table: "Transcription", comment: "A Transcribe was refused: the stored queue cannot be used")
        }
    }
}
