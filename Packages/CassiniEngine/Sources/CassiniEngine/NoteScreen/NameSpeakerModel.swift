import Foundation
import Observation
import CassiniNotebook

/// The Name a speaker sheet's state: the `SpeakerNaming` reducer, with its writes carried out through `Ports`
/// (`VoicesStore` in the app). While they are written the sheet takes no events; it closes only once they have landed,
/// and a failure keeps it open with its alert. Writes are refused while the transcript is read-only (a job is pending
/// for the note): a speaker analysis would put its own speakers over the names. What only the sheet can do (play a
/// sample, focus the question, close) goes back to it as a `SheetAction`.
@MainActor @Observable
public final class NameSpeakerModel {
    public struct Ports {
        /// What the sheet needs about the speaker; nil when the note or the speaker is gone.
        public var input: @MainActor (UUID, String) async -> NamingInput?
        /// Carries out the sheet's writes for the speaker: the note first, then the saved voices.
        public var perform: @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void
        /// Why the note's transcript cannot be changed now.
        public var readOnly: @MainActor () -> ReadOnlyReason?

        public init(input: @escaping @MainActor (UUID, String) async -> NamingInput?,
                    perform: @escaping @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void,
                    readOnly: @escaping @MainActor () -> ReadOnlyReason?) {
            self.input = input; self.perform = perform; self.readOnly = readOnly
        }
    }

    public enum SheetAction: Hashable, Sendable {
        case toggleSample(SampleWindow)
        case focusQuestion
        case close
    }

    /// Why the last save did not happen, shown as an alert.
    public enum Failure {
        case save(VoicesStore.SaveFailure)
        /// The transcript became read-only while the sheet was open; nothing was written.
        case readOnly(ReadOnlyReason)
    }

    public let noteID: UUID
    public let speakerID: String
    public private(set) var state: NamingState?
    /// The writes are running; the sheet takes no events meanwhile.
    public private(set) var saving = false
    public var failure: Failure?
    @ObservationIgnored private let ports: Ports

    public init(noteID: UUID, speakerID: String, ports: Ports) {
        self.noteID = noteID
        self.speakerID = speakerID
        self.ports = ports
    }

    /// Reads what the sheet needs; the name typed before Cassini was closed, `draft`, goes back into the field.
    public func open(draft: String?, sheet: @escaping @MainActor (SheetAction) -> Void) async {
        state = await ports.input(noteID, speakerID).map(SpeakerNaming.open)
        if let draft { send(.nameChanged(draft), sheet: sheet) }
    }

    /// Waits until the writes asked for so far have landed (tests).
    public func settle() async { await saveTask?.value }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public func send(_ event: NamingEvent, sheet: @escaping @MainActor (SheetAction) -> Void) {
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
        if let reason = ports.readOnly() {
            failure = .readOnly(reason)
            return
        }
        saving = true
        saveTask = Task {
            do throws(VoicesStore.SaveFailure) {
                try await ports.perform(writes, noteID, speakerID)
                sheet(.close)
            } catch {
                failure = .save(error)
            }
            saving = false
        }
    }
}
