import Foundation
import CassiniNotebook

extension ResultNotification {
    /// The notification that tells how a job of the note ended (`title` is the note's when the job began, `note` the
    /// note now, read for a sealed outcome). Nil when nothing is told: a pause shows as the Note's TX_PAUSED banner,
    /// and the paused-by-iOS notification is posted where the background time ends; nil too for a sealed note that is
    /// gone.
    static func announcing(_ outcome: JobOutcome, noteID: UUID, title: String, note: Note?) -> ResultNotification? {
        let kind: Kind
        switch outcome {
        case .done, .adoptPending:
            guard let note else { return nil }
            return ResultNotification(noteID: note.id, title: note.title,
                                      kind: .transcribed(speakers: note.speakers?.count ?? 0, duration: note.duration))
        case .failed(let failure): kind = .failed(failure)
        case .downloadFailed(let download): kind = .failed(.download(download.error))
        case .needsConsent: kind = .readyToTranscribe
        case .paused, .cancelled: return nil
        }
        return ResultNotification(noteID: noteID, title: title, kind: kind)
    }
}
