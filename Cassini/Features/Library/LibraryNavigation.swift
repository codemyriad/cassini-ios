import Foundation
import CassiniEngine

extension LibraryScreenModel {
    /// Sends where the Library leads to the router, and a refused Transcribe to the error presenter.
    func connect(router: Router, errors: ErrorPresenter) {
        onEffect = { [weak router, weak errors] effect in
            switch effect {
            case .openNote(let route): router?.show(route)
            case .openRecording: router?.presentRecording()
            case .openSettings: router?.show(.settings)
            case .openModelDownload(let noteID): router?.show(.modelDownload(noteID: noteID))
            case .refused(let refusal): errors?.present(refusal.message)
            }
        }
    }
}
