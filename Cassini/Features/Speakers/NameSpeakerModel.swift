import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The Name a speaker sheet's state: the `SpeakerNaming` reducer, with its writes carried out by `VoicesStore`. While
/// they are written the sheet stays; a failure keeps it open with its alert. What only the sheet can do (play a
/// sample, focus the question, close) goes back to it as a `SheetAction`.
@MainActor @Observable final class NameSpeakerModel {
    enum SheetAction {
        case toggleSample(SampleWindow)
        case focusQuestion
        case close
    }

    let noteID: UUID
    let speakerID: String
    private(set) var state: NamingState?
    /// The writes are running; the sheet takes no events meanwhile.
    private(set) var saving = false
    /// Why the last save failed, shown as an alert.
    var saveError: String?

    init(noteID: UUID, speakerID: String) {
        self.noteID = noteID
        self.speakerID = speakerID
    }

    /// Reads what the sheet needs; the name typed before Cassini was closed, `draft`, goes back into the field.
    func open(voices: VoicesStore, draft: String?, sheet: @escaping @MainActor (SheetAction) -> Void) async {
        state = await voices.namingInput(noteID: noteID, speakerID: speakerID).map(SpeakerNaming.open)
        if let draft { send(.nameChanged(draft), voices: voices, sheet: sheet) }
    }

    func send(_ event: NamingEvent, voices: VoicesStore, sheet: @escaping @MainActor (SheetAction) -> Void) {
        guard let current = state, !saving else { return }
        let result = SpeakerNaming.reduce(current, event)
        for effect in result.effects {
            switch effect {
            case .playRange(let window): sheet(.toggleSample(window))
            case .focusQuestion: sheet(.focusQuestion)
            default: break
            }
        }
        let writes = result.writes
        guard !writes.isEmpty else {
            if let next = result.state { state = next } else { sheet(.close) }
            return
        }
        saving = true
        Task {
            do throws(VoicesStore.SaveFailure) {
                try await voices.perform(writes, noteID: noteID, speakerID: speakerID)
                sheet(.close)
            } catch {
                saveError = error.message
            }
            saving = false
        }
    }
}
