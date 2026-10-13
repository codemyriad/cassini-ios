import Foundation
import Observation
import CassiniNotebook

/// The end of a recording: the note sealed with its title and duration, then its audio compressed and handed to
/// transcription.
extension RecordingController {
    func end(_ stop: Stop, title: String?) async {
        guard let current = state.activeRecording else { return }
        policy?.cancel(); policy = nil
        titleWrite?.cancel(); await titleWrite?.value; titleWrite = nil
        let id = current.noteID
        setState(.finishing(noteID: id))
        let elapsed = parts.capture.elapsed
        let duration = (try? await parts.capture.stop().duration) ?? elapsed
        let url = captureURL
        captureURL = nil
        parts.liveActivity?.end()
        activity = nil

        guard let url, Self.hasAudio(at: url) else {
            try? await parts.notes.discard(id)
            setState(.ended(noteID: nil, outcome: .microphoneFailed))
            return
        }
        let finalTitle = NoteTitles.clean(title ?? current.title) ?? current.defaultTitle
        let tooLong = duration > Limits.maxTranscribeDuration
        let after = stop == .user ? await next(tooLong: tooLong) : .audioOnly
        // Marked queued at once: a kill before the hand-off leaves the note interrupted, not silently audio only.
        let status: NoteStatus = after == .transcribe ? .queued : .audioOnly
        let seal: @Sendable (inout Note) -> Void = { note in
            note.title = finalTitle; note.duration = duration; note.audio = .plain; note.status = status
            if tooLong { note.failure = .long }
        }
        let sealed = (try? await parts.notes.update(id, seal)) ?? nil
        if sealed == nil {
            // Stays live on disk until the next launch's recovery; on screen it is a plain note now.
            await parts.notes.showUnsaved(id) { seal(&$0); $0.status = .audioOnly }
        }
        let outcome: RecordingOutcome = switch stop {
        case .user: .saved(sealed == nil ? .audioOnly : after)
        case .space: .stoppedForSpace
        case .microphone: .microphoneFailed
        }
        if sealed != nil { compress(id, url, thenTranscribe: after == .transcribe) }
        setState(.ended(noteID: id, outcome: outcome))
        if stop != .user, !isAppActive, let notifier = parts.notifier {
            let notification = ResultNotification(noteID: id, title: finalTitle,
                                                  kind: stop == .space ? .recordingStopped : .microphoneFailed)
            Task { await notifier.post(notification) }
        }
    }

    /// After a saved recording: transcription with consent (recorded, or nothing to download), else the consent
    /// question or audio only. A recording longer than one transcription takes stays audio only, as does every one
    /// while automatic transcription is off.
    func next(tooLong: Bool) async -> AfterFinish {
        let settings = parts.settings
        guard !tooLong, settings.autoTranscribe else { return .audioOnly }
        if await parts.consent.allows(.transcribe, settings.speechLanguage) { return .transcribe }
        return settings.modelsDeclinedAt != nil ? .audioOnly : .askConsent
    }

    /// Reads the waveform, compresses the capture to M4A and hands the note to transcription.
    func compress(_ id: UUID, _ capture: URL, thenTranscribe transcribe: Bool) {
        finalizing.insert(id)
        parts.handoff.audioFinalizing(id)
        compressions[id] = Task { [weak self] in
            guard let self else { return }
            defer { compressions[id] = nil } // Last, so `settle()` waits for the hand-off too.
            let readable = await finishAudio(id, capture)
            finalizing.remove(id)
            parts.handoff.audioReady(id)
            // Cancelled while compressing ("Waiting to transcribe" shows Cancel): the user's choice stands.
            guard transcribe, await parts.notes.note(id)?.status == .queued else { return }
            let queued = readable ? await parts.handoff.handOff(id) : false
            if !queued {
                _ = try? await parts.notes.update(id) { if $0.status == .queued { $0.status = .audioOnly } }
            }
        }
    }

    /// False when the capture cannot be read; its note then shows that the audio could not be read.
    func finishAudio(_ id: UUID, _ capture: URL) async -> Bool {
        let notes = parts.notes
        guard let summary = try? await parts.audio.inspect(capture) else {
            _ = try? await notes.update(id) { $0.failure = .audio }
            return false
        }
        _ = try? await notes.update(id) { $0.duration = summary.duration; $0.waveform = summary.waveform }
        let compressed = capture.deletingLastPathComponent().appendingPathComponent(Self.compressedFilename)
        do {
            try await parts.audio.compress(capture, to: compressed)
            if try await notes.update(id, { $0.audioFilename = Self.compressedFilename }) != nil {
                try? FileManager.default.removeItem(at: capture)
            } else {
                try? FileManager.default.removeItem(at: compressed)
            }
        } catch {
            try? FileManager.default.removeItem(at: compressed)
            onCompressionFailed?(id)
        }
        return true
    }
}
