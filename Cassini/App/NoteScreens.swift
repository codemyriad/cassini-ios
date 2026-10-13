import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Builds the Note screen's model over the app's stores: `NoteScreenModel.Ports` bound to the library, the voices,
/// the queue, the player, the exports, Recently Deleted and the router. The screen's problems are worded here.
@MainActor @Observable final class NoteScreens {
    @ObservationIgnored let ports: NoteScreenModel.Ports

    init(ports: NoteScreenModel.Ports) { self.ports = ports }

    func model(_ noteID: UUID, query: String?) -> NoteScreenModel {
        NoteScreenModel(noteID: noteID, query: query, ports: ports)
    }
}

extension AppGraph {
    static func noteScreens(library: LibraryStore, voices: VoicesStore, processing: ProcessingStore,
                            playback: PlaybackStore, recording: RecordingStore, exports: ExportStore,
                            trash: TrashService, router: Router, errors: ErrorPresenter) -> NoteScreens {
        NoteScreens(ports: .init(
            note: { library.note($0) }, job: { processing.state.jobs[$0] },
            update: { _ = library.update($0, $1) }, commit: { await library.commit($0, $1) },
            markMoment: { library.markMoment($0, at: $1) },
            removeBookmark: { library.removeBookmark($1, from: $0) },
            addSpeaker: { voices.addSpeaker(noteID: $0, name: $1) },
            selectVersion: { voices.selectTranscriptVersion(noteID: $0, versionID: $1) },
            answerSuggestion: { suggestion, noteID, yes throws(VoicesStore.SaveFailure) in
                if yes { try await voices.accept(suggestion, noteID: noteID) } else { try await voices.reject(suggestion, noteID: noteID) }
            },
            namingInput: { await voices.namingInput(noteID: $0, speakerID: $1) },
            performNaming: { effects, noteID, speakerID throws(VoicesStore.SaveFailure) in
                try await voices.perform(effects, noteID: noteID, speakerID: speakerID)
            },
            transcribe: { await processing.transcribe($0, kind: $1) }, startOver: { await processing.startOver($0) },
            stop: { processing.stop($0) }, dequeue: { processing.dequeue($0) },
            continueQueue: { processing.continueQueue() }, clearFailed: { processing.clearFailed($0) },
            cancelJobDownload: { processing.cancelJobDownload() },
            savedDraft: { await processing.savedDraft($0) },
            speakerModelsReady: { await processing.speakerModelsReady() },
            ownsPlayer: { playback.owns($0) }, play: { playback.play() }, playFrom: { playback.play($0, from: $1) },
            showPlayer: { playback.show($0, owner: $1) }, leavePlayer: { playback.leave($0) },
            playerBlocked: { playback.isBlocked }, recording: { recording.state.isActive },
            exportTranscript: { id, format throws(ExportError) in try await exports.exportTranscript(id, format: format) },
            copyAudio: { id throws(ExportError) in try await exports.copyAudio(id) },
            exportDocument: { try await exports.exportPortable($0) },
            discardExport: { exports.discard($0) },
            trash: { _ = await trash.requestTrash($0) },
            session: { router.session($0) }, isOpen: { router.isOpen($0) }, markStarted: { router.markStarted($0) },
            openModelDownload: { router.offerModelDownload(for: $0) },
            present: { errors.present($0.message) }))
    }
}

extension NoteProblem {
    /// The problem as the error alert says it.
    var message: String {
        switch self {
        case .refused(let refusal): refusal.message
        case .export(let error): ExportCopy.message(error)
        case .documentNotSaved: ExportCopy.notSaved
        case .speakerNotSaved(let failure): failure.message
        }
    }
}
