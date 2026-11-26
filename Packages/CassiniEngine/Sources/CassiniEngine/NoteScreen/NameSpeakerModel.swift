import Foundation
import Observation
import CassiniNotebook

/// The Name a speaker sheet's state: a `SpeakerSheetSession` over the `SpeakerNaming` reducer, with its writes carried
/// out through `Ports` (`VoicesStore` in the app). While they are written the sheet takes no events; it closes only
/// once they have landed, and a failure keeps it open with its alert. Writes are refused while the transcript is
/// read-only (a job is pending for the note): a speaker analysis would put its own speakers over the names. What only
/// the sheet can do (play a sample, focus the question, close) goes back to it as a `SheetAction`.
@MainActor @Observable
public final class NameSpeakerModel {
    public struct Ports {
        /// What the sheet needs about the speaker; nil when the note or the speaker is gone.
        public var input: @MainActor (UUID, String) async -> NamingInput?
        /// Carries out the sheet's writes for one speaker: the note first, then the saved voices.
        public var perform: @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void
        /// Carries out a multi-speaker batch save and returns an Undo snapshot when available.
        public var performBatch: (@MainActor ([SpeakerSheetSession.BatchWrite], UUID) async throws(VoicesStore.SaveFailure) -> VoicesStore.SpeakerUndoSnapshot?)?
        /// Called after a successful batch save with the toast summary and Undo snapshot.
        public var onSaved: (@MainActor (SpeakerSheetSession.SaveSummary, VoicesStore.SpeakerUndoSnapshot?) -> Void)?
        /// Off-main canonical roster loader when the caller did not have a cached `allHeaderSpeakers` snapshot.
        public var prepareRoster: (@MainActor () async -> [SpeakerSheetSession.RowSpeaker])?
        /// Why the note's transcript cannot be changed now.
        public var readOnly: @MainActor () -> ReadOnlyReason?

        public init(input: @escaping @MainActor (UUID, String) async -> NamingInput?,
                    perform: @escaping @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void,
                    readOnly: @escaping @MainActor () -> ReadOnlyReason?,
                    performBatch: (@MainActor ([SpeakerSheetSession.BatchWrite], UUID) async throws(VoicesStore.SaveFailure) -> VoicesStore.SpeakerUndoSnapshot?)? = nil,
                    onSaved: (@MainActor (SpeakerSheetSession.SaveSummary, VoicesStore.SpeakerUndoSnapshot?) -> Void)? = nil,
                    prepareRoster: (@MainActor () async -> [SpeakerSheetSession.RowSpeaker])? = nil) {
            self.input = input; self.perform = perform; self.readOnly = readOnly
            self.performBatch = performBatch; self.onSaved = onSaved; self.prepareRoster = prepareRoster
        }
    }

    public enum SheetAction: Hashable, Sendable {
        case toggleSample(SampleWindow)
        case stopSample
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
    public private(set) var session: SpeakerSheetSession
    /// The writes are running; the sheet takes no events meanwhile.
    public private(set) var saving = false
    public var failure: Failure?
    @ObservationIgnored private let ports: Ports
    @ObservationIgnored private let displayLabel: (NamingInput) -> String

    public var activeSpeakerID: String { session.selectedSpeakerID }
    public var state: NamingState? { session.currentState }
    public var displayedRoster: [SpeakerSheetSession.RowSpeaker] { session.displayedRoster }
    public var combinedSaveState: SaveState { session.saveState }

    public init(noteID: UUID, speakerID: String, roster: [SpeakerSheetSession.RowSpeaker] = [],
                displayLabel: @escaping (NamingInput) -> String = { $0.label }, ports: Ports) {
        self.noteID = noteID
        self.speakerID = speakerID
        self.session = SpeakerSheetSession(roster: roster, selectedSpeakerID: speakerID)
        self.displayLabel = displayLabel
        self.ports = ports
    }

    /// Reads what the sheet needs; the name typed before Cassini was closed, `draft`, goes back into the field.
    public func open(draft: String?, sheet: @escaping @MainActor (SheetAction) -> Void) async {
        async let loadedInput = ports.input(noteID, speakerID)
        if let roster = await ports.prepareRoster?(), !roster.isEmpty {
            session.updateRoster(roster)
        }
        if let input = await loadedInput {
            session.setLoaded(input)
        }
        if let draft { send(.nameChanged(draft), sheet: sheet) }
    }

    /// Switches to another speaker in the top row without closing the sheet, preserving unsaved edits.
    public func selectSpeaker(_ id: String, sheet: @escaping @MainActor (SheetAction) -> Void) async {
        guard !saving, Data(id.utf8) != Data(session.selectedSpeakerID.utf8) else { return }
        sheet(.stopSample)
        session.select(id)
        if session.currentState == nil, let input = await ports.input(noteID, id) {
            session.setLoaded(input)
        }
    }

    /// Waits until the writes asked for so far have landed (tests).
    public func settle() async { await saveTask?.value }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public func send(_ event: NamingEvent, sheet: @escaping @MainActor (SheetAction) -> Void) {
        guard let current = state, !saving else { return }
        if case .save = event {
            saveAll(sheet: sheet)
            return
        }
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
            if let next = result.state {
                session.drafts[Data(session.selectedSpeakerID.utf8)] = next
            } else {
                sheet(.close)
            }
            return
        }
        if let reason = ports.readOnly() {
            failure = .readOnly(reason)
            return
        }
        let targetID = session.selectedSpeakerID
        saving = true
        saveTask = Task {
            do throws(VoicesStore.SaveFailure) {
                try await ports.perform(writes, noteID, targetID)
                sheet(.close)
            } catch {
                failure = .save(error)
            }
            saving = false
        }
    }

    private func saveAll(sheet: @escaping @MainActor (SheetAction) -> Void) {
        if let blocker = session.blockingSpeakerID {
            if Data(blocker.utf8) != Data(session.selectedSpeakerID.utf8) {
                sheet(.stopSample)
                session.select(blocker)
            }
            sheet(.focusQuestion)
            return
        }
        let (writes, summary) = session.pendingSave(displayLabel: displayLabel)
        guard !writes.isEmpty else { return }
        if let reason = ports.readOnly() {
            failure = .readOnly(reason)
            return
        }
        saving = true
        saveTask = Task {
            do throws(VoicesStore.SaveFailure) {
                let snapshot: VoicesStore.SpeakerUndoSnapshot?
                if let performBatch = ports.performBatch {
                    snapshot = try await performBatch(writes, noteID)
                } else {
                    for write in writes {
                        try await ports.perform(write.effects, noteID, write.speakerID)
                    }
                    snapshot = nil
                }
                ports.onSaved?(summary, snapshot)
                sheet(.close)
            } catch {
                failure = .save(error)
            }
            saving = false
        }
    }
}
