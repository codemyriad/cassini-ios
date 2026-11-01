import Foundation
import CassiniNotebook

/// What happens to a note once it is saved, and the Cancel of a running job's model download.
///
/// Touches: `active` (marks its Cancel mode and stops it); everything else through the queue actions.
extension TranscriptionCoordinator {
    /// After a recording or an import is saved, with Transcribe automatically on: the note is queued when the models
    /// may be used, the model download screen should ask when the person has not declined it, and otherwise the note
    /// stays audio only. Audio longer than one transcription takes stays audio only too. The automatic request never
    /// clears a hold.
    public func handOff(_ noteID: UUID) async -> HandOff {
        guard !finalizing.contains(noteID) else { return .audioOnly }
        await readiness.wait()
        guard let note = await parts.notes.note(noteID), note.duration <= Limits.maxTranscribeDuration else {
            return .audioOnly
        }
        let language = EnqueueRules.language(for: .transcribe, speechLanguage: settings.speechLanguage) ?? ""
        guard await parts.consent.allows(.transcribe, language) else {
            return settings.modelsDeclinedAt == nil ? .askConsent : .audioOnly
        }
        if case .queued = await transcribe(noteID, origin: .automatic) { return .queued }
        return .audioOnly
    }

    /// The download notice's Cancel while the running job downloads a model (its phase is downloading, whatever its
    /// progress): the job stops, the files fetched so far stay, and the note goes back to its state from before:
    /// paused by the user with its saved progress, else without a job ("Audio only" for a first Transcribe). False
    /// when no job downloads; the standalone install is then the one to cancel.
    @discardableResult
    public func cancelDownload() -> Bool {
        guard let current = active, case .downloading = state.running?.phase else { return false }
        // A Start over at the same moment keeps its discard.
        if current.cancel == nil { current.cancel = .restore }
        current.stop.stop(.pause(.user))
        return true
    }
}
