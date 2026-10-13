import Foundation
import CassiniNotebook

/// The result notifications, posted only while Cassini is not on the screen.
extension TranscriptionCoordinator {
    /// The result notification of `outcome`, only while Cassini is not on the screen.
    func announce(_ current: Active, _ outcome: JobOutcome) async {
        switch outcome {
        case .done, .adoptPending:
            guard let note = await parts.notes.note(current.noteID) else { return }
            await notifyHidden(note.id, note.title, .transcribed(speakers: note.speakers?.count ?? 0, duration: note.duration))
        case .failed(let failure):
            await notifyHidden(current.noteID, current.title, .failed(failure))
        case .downloadFailed(let download):
            await notifyHidden(current.noteID, current.title, .failed(.download(download.error)))
        case .needsConsent:
            await notifyHidden(current.noteID, current.title, .readyToTranscribe)
        case .paused, .cancelled:
            // A pause shows as the Note's TX_PAUSED banner; the paused-by-iOS notification is posted where the
            // background time ends.
            break
        }
    }


    func notifyHidden(_ noteID: UUID, _ title: String, _ kind: ResultNotification.Kind) async {
        guard !visible else { return }
        await parts.notifier.post(ResultNotification(noteID: noteID, title: title, kind: kind))
    }
}
