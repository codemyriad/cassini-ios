import Foundation
import CassiniEngine
import CassiniNotebook

extension Router {
    /// A note link (a notification tap): the note on top, popped to when it is already open, with the Library at the
    /// bottom. Recording, a cover over everything, gives way; a recording in progress goes on.
    func open(link noteID: UUID) {
        dismissRecording()
        set(DeepLinks.note(stack, noteID))
    }
}

/// Carries out the deep links: notification taps and their Resume action, and the Live Activity's tap. A link that
/// arrives on a cold start waits for the launch work, so the note it names is loaded.
@MainActor struct DeepLinkHandler {
    let router: Router
    let library: LibraryStore
    let processing: ProcessingStore
    let recording: RecordingStore
    let ready: @MainActor () async -> Void

    func handle(_ link: DeepLink) async {
        await ready()
        switch link {
        case .recording:
            recording.returnToRecording()
        case .note(let id, let resume):
            guard let note = library.note(id), note.trashedAt == nil else { return }
            router.open(link: id)
            guard resume else { return }
            // Resume from the notification: the job goes on from its saved progress, as from the screen.
            let kind = processing.state.jobs[id]?.kind ?? .transcribe
            if await processing.transcribe(id, kind: kind, origin: .screen) == .needsConsent {
                router.offerModelDownload(for: id)
            }
        }
    }
}
