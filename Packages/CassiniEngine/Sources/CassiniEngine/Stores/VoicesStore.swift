import Foundation
import Synchronization
import Observation
import CassiniNotebook

/// Saved voices and the speakers of each note: the app's side of `VoiceStore`. Naming effects are worked out by
/// `NamingCommit` and written note first, voices after; the voice side is worked out again on the `VoiceStore` actor
/// against the voices as they are then, so overlapping edits keep each other. A voice write that fails puts the note's
/// links back.
@MainActor @Observable public final class VoicesStore {
    /// The saved voices could not be read; their files are kept.
    public struct Unavailable: Error {}

    /// Why a speaker could not be saved, shown in the speaker sheet.
    public struct SaveFailure: Error {
        public enum Reason: Sendable {
            /// The saved voices can't be changed now; nothing was changed.
            case voicesReadOnly
            /// The speaker said too little to remember their voice.
            case tooLittleSpeech
            /// The note could not be written; nothing was changed.
            case noteNotSaved
            /// The note was written but the saved voices were not, so the note's links went back.
            case voiceNotSaved(any Error)
        }

        public let reason: Reason

        public init(reason: Reason) { self.reason = reason }
    }

    public private(set) var snapshot = VoiceSnapshot()
    /// The private voice files could not be opened at launch.
    public private(set) var loadFailed = false
    @ObservationIgnored public private(set) var store: VoiceStore?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let clock: any AppClock
    /// Whether the voiceprint model (CAM++) is installed, so a speaker without a print can be remembered once the next
    /// analysis makes one ("Recognising voices isn't downloaded" otherwise). The app sets it from its analyzer.
    @ObservationIgnored public var printsReady: @Sendable () async -> Bool = { false }
    /// The draft names of running and paused jobs, which Forget and Forget everyone scrub too.
    @ObservationIgnored public var drafts: DraftNamesStore?
    /// Test-only hook invoked right before each batch step executes (after staging/validation).
    @ObservationIgnored var beforeBatchStep: (@MainActor (_ stepIndex: Int, _ speakerID: String) async throws(SaveFailure) -> Void)?
    /// The saved voices for a running job's live matching, readable from any thread.
    public nonisolated let liveVoices = LiveVoices()

    public init(library: LibraryStore, settings: SettingsStore, clock: any AppClock) {
        self.library = library; self.settings = settings; self.clock = clock
    }

    public var savedVoices: [SavedVoice] { snapshot.voices }
    /// The saved voices cannot be changed: newer, damaged or unreadable, or the private folder could not be opened.
    public var isReadOnly: Bool { store == nil || snapshot.isReadOnly }
    public var hasEvidence: Bool { snapshot.hasEvidence }
    /// "Saved voices can't be read": the files could not be opened, were written by a newer Cassini or cannot be read
    /// now. A damaged list is not: Saved voices offers to start it again.
    public var isUnavailable: Bool { loadFailed || snapshot.problem == .newer || snapshot.problem == .unreadable }
    /// Whether Saved voices offers Forget all voice data with no person listed: there are prints to delete, or the list
    /// is damaged and only Forget everyone starts it again.
    public var offersForgetAllData: Bool { snapshot.canForgetEveryone && (hasEvidence || snapshot.problem == .damaged) }

    /// Saved voices as the screen lists them.
    public var summaries: [SavedVoiceSummary] {
        SavedVoiceList.summaries(savedVoices, notes: library.notes, model: VoiceprintModel.sha256,
                                 dimension: VoiceprintModel.dimension)
    }

    public func voice(_ id: UUID?) -> SavedVoice? { id.flatMap { id in savedVoices.first { $0.id == id } } }

    /// The "Is this Luca?" cards of a note.
    public func suggestions(for note: Note) -> [SpeakerSuggestion] { SpeakerSuggestions.of(note, voices: savedVoices) }

    /// Opens the private voice files, off the main actor. False when they cannot be used as they are; they are kept.
    @discardableResult public func load() async -> Bool {
        guard let root = library.root else { return false }
        let clock = clock
        do {
            store = try await Task.detached { try VoiceStore(root: root, now: { clock.now }) }.value
        } catch {
            loadFailed = true
            return false
        }
        await refresh()
        return !snapshot.isReadOnly
    }

    public func refresh() async {
        guard let store else { return }
        snapshot = await store.snapshot()
        liveVoices.set(snapshot.isReadOnly ? [] : snapshot.voices, generation: settings.voicesGeneration)
    }

    /// Reads the saved voices again when the last read failed for a passing reason, before they are used.
    private func retryUnreadable() async {
        if snapshot.problem == .unreadable { await refresh() }
    }

    /// Drops the voiceprints of notes that no longer exist, at launch. A note folder that could not be read keeps its
    /// prints (`VoiceLibrary.sweepOrphans`).
    public func sweepOrphans() async throws {
        guard let store, library.loadFailure == nil else { return }
        try await store.sweepOrphans(keeping: Set(library.notes.map(\.id)))
        await refresh()
    }

    // MARK: - Speaker analysis

    /// Puts a finished analysis into the note: speakers of their own, attributed passages, and matches to saved voices
    /// and to the note's own named speakers (`AnalysisMatches`), so their names carry over. Voiceprints are kept, and
    /// voices matched, only while `generation` is still current: an analysis that began before Forget everyone keeps
    /// nothing. Forget everyone may also run while the analysis is being put in: the prints are written only when no
    /// forget ran on the `VoiceStore` actor since their read, and the matches are dropped when the generation moved on
    /// before the note is written, so neither a print nor a link to a forgotten voice comes back.
    public func applySpeakerAnalysis(_ analysis: SpeakerAnalysis, to id: UUID, generation: Int) async throws {
        await retryUnreadable()
        guard let note = library.note(id), note.trashedAt == nil else { return }
        // Streamed speakers have ids of their own run already, the words' ids; a whole-file analysis's get a namespace.
        let attributed = analysis.transcript
        let (turns, prints) = attributed != nil ? (analysis.turns, analysis.prints)
            : SpeakerAttribution.namespaced(turns: analysis.turns, prints: analysis.prints, prefix: UUID().uuidString + "_")
        // The draft's "Not Luca" answers, and the voices confirmed for another speaker, are never matched.
        let excluded = analysis.names?.excluded(Set(prints.map(\.speakerID)).union(turns.map(\.speakerID))) ?? [:]
        var matching = AnalysisMatches()
        if generation == settings.voicesGeneration, let store {
            let (earlier, count) = await store.printsForAnalysis(noteID: id)
            // A note's prints are kept even if the saved voices can't be changed now; the note keeps working without.
            let kept = (try? await store.appendPrints(prints, noteID: id, ifForgottenCount: count)) ?? true
            if kept, generation == settings.voicesGeneration {
                matching = AnalysisMatches.of(note, turns: turns, prints: prints, savedVoices: settings.recogniseSavedVoices ? savedVoices : [],
                                              earlierPrints: earlier,
                                              trashed: Set(library.notes.filter { $0.trashedAt != nil }.map(\.id)),
                                              excluded: excluded)
            }
        }
        // Forget everyone that began since the matches were worked out drops them: its links are gone already.
        if generation != settings.voicesGeneration { matching = AnalysisMatches() }
        let autoName = settings.automaticallyNameVoices
        let stamp = VersionStamp(date: clock.now)
        let names = analysis.names
        let labels = names?.labels ?? [:]
        let saved = await library.commit(id) { [matching] note in
            guard note.trashedAt == nil else { return }
            matching.apply(to: &note, turns: turns, autoName: autoName, stamp: stamp,
                           attributed: attributed.flatMap { Self.attributed($0, onto: note) }, excluded: excluded,
                           labels: labels, colourIndices: names?.colourIndices ?? [:], explicitNames: names?.explicitNames ?? [])
        }
        guard saved != nil else { throw CocoaError(.fileWriteUnknown) }
        await refresh()
        if let names { await enrol(names, noteID: id, generation: generation) }
    }

    /// The draft's Remember choices once the note holds its speakers (Android's adopt): each speaker with a name and a
    /// print is enrolled into its saved voice, or a new one, and confirmed. A choice made before Forget everyone, or
    /// for a voice forgotten since, enrols nothing; a speaker with too little speech keeps its name only.
    private func enrol(_ names: DraftNames, noteID: UUID, generation: Int) async {
        guard names.generation == generation, generation == settings.voicesGeneration else { return }
        for (speaker, voice) in names.remembered.sorted(by: { $0.key < $1.key }) {
            guard let label = names.labels[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
            else { continue }
            let voiceID: UUID?
            switch voice {
            case .new: voiceID = nil
            case .saved(let id):
                guard self.voice(id) != nil else { continue }
                voiceID = id
            }
            try? await perform([.rememberVoice(speakerID: speaker, voiceID: voiceID, name: label)], noteID: noteID,
                               speakerID: speaker)
        }
    }

    /// The streamed words with their speakers, as the note's passages: only while the note still holds those words
    /// (the job saved them in one voice just before), else nil and the note attributes them itself.
    nonisolated static func attributed(_ segments: [TranscriptSegment], onto note: Note) -> [TranscriptSegment]? {
        ProvenanceRecord.fingerprint(of: segments) == ProvenanceRecord.fingerprint(of: note.transcript) ? segments : nil
    }

    // MARK: - Naming

    /// What the Name a speaker sheet needs about the speaker; nil when the note or the speaker is gone.
    public func namingInput(noteID: UUID, speakerID: String) async -> NamingInput? {
        await retryUnreadable()
        guard let note = library.note(noteID), note.speaker(speakerID) != nil else { return nil }
        let print = await print(noteID: noteID, speakerID: speakerID)
        let voices = savedVoices
        let readOnly = isReadOnly
        let ready = await printsReady()
        let rememberDefault = settings.rememberPeopleIName
        return await Task.detached(priority: .userInitiated) {
            NamingInput.of(note, speakerID: speakerID, print: print, voices: voices, voicesReadOnly: readOnly,
                           voiceModelReady: ready, rememberDefault: rememberDefault)
        }.value
    }

    /// Carries out the sheet's effects for one speaker: the note first, then the saved voices.
    public func perform(_ effects: [NamingEffect], noteID: UUID, speakerID: String) async throws(SaveFailure) {
        await retryUnreadable()
        guard let note = library.note(noteID), let speaker = note.speaker(speakerID) else { return }
        let print = await print(noteID: noteID, speakerID: speakerID)
        let newVoiceID = UUID(), stamp = VersionStamp(date: clock.now)
        let plan: @Sendable ([SavedVoice], Bool) -> NamingCommit = { voices, readOnly in
            NamingCommit.plan(effects, noteID: noteID, speaker: speaker, print: print, voices: voices, voicesReadOnly: readOnly,
                              newVoiceID: newVoiceID, stamp: stamp)
        }
        let commit = plan(savedVoices, isReadOnly)
        switch commit.refused {
        case .readOnly?: throw SaveFailure(reason: .voicesReadOnly)
        case .noPrint?: throw SaveFailure(reason: .tooLittleSpeech)
        case nil: try await write(commit, plan: plan, noteID: noteID, before: note)
        }
    }

    /// Pending rollback snapshots retained when a mid-batch failure also could not persist its inverse voice writes
    /// (e.g. voice storage remained unwritable). Cleared only after `retryPendingRollback(noteID:)` succeeds.
    public private(set) var pendingRollback: [UUID: SpeakerUndoSnapshot] = [:]

    /// A voice link scrubbed by `unlinkVoice` when a voice's last sample was removed, bound to its originating
    /// transcript version (or unversioned revision when `versionID` is nil) so Undo/rollback never corrupts another version.
    public struct ScrubbedVoiceLink: Equatable, Sendable {
        public let noteID: UUID
        public let versionID: UUID?
        public let speakerID: String
        public let match: VoiceMatchState
        public let expectedUnversionedSpeakers: [NoteSpeaker]?
        public init(noteID: UUID, versionID: UUID?, speakerID: String, match: VoiceMatchState,
                    expectedUnversionedSpeakers: [NoteSpeaker]? = nil) {
            self.noteID = noteID; self.versionID = versionID; self.speakerID = speakerID; self.match = match
            self.expectedUnversionedSpeakers = expectedUnversionedSpeakers
        }
    }

    /// One recorded inverse voice operation with any cross-note links scrubbed when its voice was forgotten.
    public struct RecordedVoiceUndoOp: Equatable, Sendable {
        public let op: NamingCommit.VoiceUndoOp
        public let scrubbedLinks: [ScrubbedVoiceLink]
        public init(op: NamingCommit.VoiceUndoOp, scrubbedLinks: [ScrubbedVoiceLink] = []) {
            self.op = op; self.scrubbedLinks = scrubbedLinks
        }
    }

    /// Version-bound snapshot of a Name a speaker batch Save, for Undo (D112 / L-86).
    public struct SpeakerUndoSnapshot: Equatable, Sendable {
        public let versionID: UUID?
        public let afterSpeakers: [NoteSpeaker]?
        public let speakerEntries: [Note.SpeakerUndoEntry]
        public let voiceOps: [RecordedVoiceUndoOp]
        public init(versionID: UUID? = nil, afterSpeakers: [NoteSpeaker]? = nil,
                    speakerEntries: [Note.SpeakerUndoEntry] = [], voiceOps: [RecordedVoiceUndoOp] = []) {
            self.versionID = versionID
            self.afterSpeakers = afterSpeakers
            self.speakerEntries = speakerEntries
            self.voiceOps = voiceOps
        }
    }

    /// Carries out a batch of speaker saves with upfront staging/validation, transaction-level rollback on failure,
    /// and a version-bound Undo snapshot recording inverse voice operations in effect order.
    public func performBatch(_ writes: [SpeakerSheetSession.BatchWrite], noteID: UUID) async throws(SaveFailure) -> SpeakerUndoSnapshot {
        await retryUnreadable()
        guard let beforeNote = library.note(noteID) else { return SpeakerUndoSnapshot() }
        let targetVersionID = beforeNote.shownVersionID
        let allPrints = (try? await store?.prints(noteID: noteID)) ?? []
        var latestPrintBySpeaker: [Data: SpeakerPrint] = [:]
        for item in allPrints { latestPrintBySpeaker[Data(item.speakerID.utf8)] = item }

        // Stage and validate the full batch before mutating any note or voice file.
        struct StagedWrite {
            let write: SpeakerSheetSession.BatchWrite
            let print: SpeakerPrint?
            let newVoiceID: UUID
            let stamp: VersionStamp
        }
        var simNote = beforeNote
        var simVoices = savedVoices
        let readOnly = isReadOnly
        var staged: [StagedWrite] = []
        staged.reserveCapacity(writes.count)
        for write in writes {
            guard let simSpeaker = simNote.speaker(write.speakerID) else { continue }
            let speakerPrint = latestPrintBySpeaker[Data(write.speakerID.utf8)]
            let newVoiceID = UUID(), stamp = VersionStamp(date: clock.now)
            let commit = NamingCommit.plan(write.effects, noteID: noteID, speaker: simSpeaker, print: speakerPrint,
                                           voices: simVoices, voicesReadOnly: readOnly,
                                           newVoiceID: newVoiceID, stamp: stamp)
            switch commit.refused {
            case .readOnly?: throw SaveFailure(reason: .voicesReadOnly)
            case .noPrint?: throw SaveFailure(reason: .tooLittleSpeech)
            case nil:
                simNote.apply(commit.changes)
                simVoices = commit.voices
                for voice in commit.forgotten { simNote.unlinkVoice(voice) }
                staged.append(StagedWrite(write: write, print: speakerPrint, newVoiceID: newVoiceID, stamp: stamp))
            }
        }

        // Capture each touched speaker's original pre-batch state before any step writes.
        var beforeByID: [Data: NoteSpeaker] = [:]
        var touchedOrder: [String] = []
        for item in staged {
            let key = Data(item.write.speakerID.utf8)
            if beforeByID[key] == nil, let speaker = beforeNote.speaker(item.write.speakerID) {
                beforeByID[key] = speaker
                touchedOrder.append(item.write.speakerID)
            }
        }

        var recordedVoiceOps: [RecordedVoiceUndoOp] = []
        var committedSpeakers: [NoteSpeaker] = []
        var committedKeys = Set<Data>()
        var committedOrder: [String] = []
        var failedStepSpeaker: NoteSpeaker?

        do throws(SaveFailure) {
            for (index, item) in staged.enumerated() {
                if let hook = beforeBatchStep { try await hook(index, item.write.speakerID) }
                guard let currentNote = library.note(noteID),
                      let currentSpeaker = currentNote.speaker(item.write.speakerID) else { continue }
                let effects = item.write.effects
                let speakerPrint = item.print
                let newVoiceID = item.newVoiceID
                let stamp = item.stamp
                let plan: @Sendable ([SavedVoice], Bool) -> NamingCommit = { voices, readOnly in
                    NamingCommit.plan(effects, noteID: noteID, speaker: currentSpeaker, print: speakerPrint,
                                      voices: voices, voicesReadOnly: readOnly,
                                      newVoiceID: newVoiceID, stamp: stamp)
                }
                let commit = plan(savedVoices, isReadOnly)
                switch commit.refused {
                case .readOnly?: throw SaveFailure(reason: .voicesReadOnly)
                case .noPrint?: throw SaveFailure(reason: .tooLittleSpeech)
                case nil:
                    let key = Data(item.write.speakerID.utf8)
                    failedStepSpeaker = committedKeys.contains(key) ? nil : beforeByID[key]
                    let ops = try await writeWithUndo(commit, plan: plan, noteID: noteID, before: currentNote)
                    failedStepSpeaker = nil
                    recordedVoiceOps.append(contentsOf: ops)
                    if committedKeys.insert(key).inserted, let original = beforeByID[key] {
                        committedSpeakers.append(original)
                        committedOrder.append(item.write.speakerID)
                    }
                }
            }
        } catch {
            // If the failing step itself already wrote non-link fields before its voice write failed, restore it
            // immediately (its voice write did not land, so its pre-step links remain valid in VoiceStore).
            if let failedStepSpeaker {
                _ = await library.commit(noteID) { $0.rollbackSpeakers([failedStepSpeaker], versionID: targetVersionID) }
            }
            // Transaction-level rollback: persist inverse voice ops in strict reverse order FIRST.
            // Only restore committed note speakers and scrubbed links once voice persistence succeeds;
            // otherwise retain a retryable rollback snapshot so confirmed links never point to deleted voices.
            do throws(SaveFailure) {
                try await replayInverseVoiceOps(recordedVoiceOps)
                if !committedSpeakers.isEmpty {
                    let toRollback = committedSpeakers
                    _ = await library.commit(noteID) { $0.rollbackSpeakers(toRollback, versionID: targetVersionID) }
                }
                await restoreScrubbedLinks(recordedVoiceOps)
                pendingRollback[noteID] = nil
            } catch {
                let partialNote = library.note(noteID)
                let entries: [Note.SpeakerUndoEntry] = committedOrder.compactMap { id in
                    guard let before = beforeByID[Data(id.utf8)], let after = partialNote?.speaker(id) else { return nil }
                    return Note.SpeakerUndoEntry(speakerID: id, before: before, after: after)
                }
                pendingRollback[noteID] = SpeakerUndoSnapshot(
                    versionID: targetVersionID,
                    afterSpeakers: partialNote?.speakers,
                    speakerEntries: entries,
                    voiceOps: recordedVoiceOps
                )
            }
            throw error
        }

        pendingRollback[noteID] = nil
        let afterNote = library.note(noteID)
        let entries: [Note.SpeakerUndoEntry] = touchedOrder.compactMap { id in
            guard let before = beforeByID[Data(id.utf8)], let after = afterNote?.speaker(id) else { return nil }
            return Note.SpeakerUndoEntry(speakerID: id, before: before, after: after)
        }
        return SpeakerUndoSnapshot(versionID: targetVersionID, afterSpeakers: afterNote?.speakers,
                                   speakerEntries: entries, voiceOps: recordedVoiceOps)
    }

    /// Retries a retained mid-batch rollback once voice storage is writable again. Clears `pendingRollback[noteID]`
    /// only after voice and note restoration both succeed.
    public func retryPendingRollback(noteID: UUID) async throws(SaveFailure) {
        guard let snapshot = pendingRollback[noteID] else { return }
        try await undoSpeakerChanges(snapshot, noteID: noteID)
        pendingRollback[noteID] = nil
    }

    /// Reverts a Name a speaker batch Save on its original version, replaying inverse voice operations in strict
    /// reverse order and restoring note speakers and scrubbed links only after voice persistence succeeds.
    public func undoSpeakerChanges(_ snapshot: SpeakerUndoSnapshot, noteID: UUID) async throws(SaveFailure) {
        guard let note = library.note(noteID),
              note.canRestoreSpeakers(snapshot.speakerEntries, versionID: snapshot.versionID,
                                      expectedAfterSpeakers: snapshot.afterSpeakers)
        else { return }
        try await replayInverseVoiceOps(snapshot.voiceOps)
        let entries = snapshot.speakerEntries
        let versionID = snapshot.versionID
        let expected = snapshot.afterSpeakers
        guard await library.commit(noteID, { note in
            _ = note.restoreSpeakers(entries, versionID: versionID, expectedAfterSpeakers: expected)
        }) != nil else {
            throw SaveFailure(reason: .noteNotSaved)
        }
        await restoreScrubbedLinks(snapshot.voiceOps)
    }

    /// Replays recorded inverse voice operations in strict reverse order against `VoiceStore`.
    private func replayInverseVoiceOps(_ recorded: [RecordedVoiceUndoOp]) async throws(SaveFailure) {
        guard !recorded.isEmpty else { return }
        guard let store else { throw SaveFailure(reason: .voicesReadOnly) }
        let ops = recorded.reversed().map(\.op)
        do {
            _ = try await store.mutate { voices in
                for op in ops { NamingCommit.applyInverse(op, to: &voices) }
            }
        } catch {
            await refresh()
            throw SaveFailure(reason: .voiceNotSaved(error))
        }
        await refresh()
    }

    /// Captures all non-rejection links to `voiceID` across every note and kept version before `unlinkVoice` scrubs them,
    /// recording the originating `versionID` (and never emitting a `nil` version record for a kept version).
    private func captureScrubbedLinks(for voiceID: UUID) -> [ScrubbedVoiceLink] {
        var links: [ScrubbedVoiceLink] = []
        for note in library.notes {
            if note.shownVersionID == nil, let shown = note.speakers {
                let postUnlink = shown.map { speaker -> NoteSpeaker in
                    var copy = speaker
                    if copy.match.voiceID == voiceID && !copy.match.isRejection { copy.match = .unmatched }
                    return copy
                }
                for speaker in shown where speaker.match.voiceID == voiceID && !speaker.match.isRejection {
                    links.append(ScrubbedVoiceLink(noteID: note.id, versionID: nil, speakerID: speaker.id,
                                                   match: speaker.match, expectedUnversionedSpeakers: postUnlink))
                }
            }
            for version in note.versions ?? [] {
                for speaker in version.speakers {
                    if speaker.match.voiceID == voiceID && !speaker.match.isRejection {
                        links.append(ScrubbedVoiceLink(noteID: note.id, versionID: version.id,
                                                       speakerID: speaker.id, match: speaker.match))
                    }
                }
            }
        }
        return links
    }

    /// Restores voice links that were scrubbed when a voice's last sample was temporarily removed.
    private func restoreScrubbedLinks(_ recorded: [RecordedVoiceUndoOp]) async {
        let links = recorded.reversed().flatMap(\.scrubbedLinks)
        guard !links.isEmpty else { return }
        let byNote = Dictionary(grouping: links, by: \.noteID)
        for (targetNoteID, noteLinks) in byNote {
            _ = await library.commit(targetNoteID) { note in
                for link in noteLinks {
                    note.restoreVoiceLink(speakerID: link.speakerID, versionID: link.versionID, match: link.match,
                                          expectedUnversionedSpeakers: link.expectedUnversionedSpeakers)
                }
            }
        }
    }

    /// "Yes, Luca": names the speaker after the voice and confirms it, remembering the speaker's print in it.
    public func accept(_ suggestion: SpeakerSuggestion, noteID: UUID) async throws(SaveFailure) {
        try await perform([.relabel(speakerID: suggestion.speakerID, name: suggestion.voiceName),
                           .rememberVoice(speakerID: suggestion.speakerID, voiceID: suggestion.voiceID, name: suggestion.voiceName)],
                          noteID: noteID, speakerID: suggestion.speakerID)
    }

    /// "Not Luca": the voice is never offered for this speaker again.
    public func reject(_ suggestion: SpeakerSuggestion, noteID: UUID) async throws(SaveFailure) {
        try await perform([.reject(speakerID: suggestion.speakerID, voiceID: suggestion.voiceID, voiceName: suggestion.voiceName,
                                   unenrol: false, restorePlaceholder: false)],
                          noteID: noteID, speakerID: suggestion.speakerID)
    }

    /// Writes the note's side of `commit`, then the voices: `plan` runs again on the `VoiceStore` actor against the
    /// voices as they are then. When that gives the note other changes (a voice forgotten meanwhile), they follow; the
    /// notes drop their links to forgotten voices only once the voices are written.
    private func write(_ commit: NamingCommit, plan: @escaping @Sendable ([SavedVoice], Bool) -> NamingCommit,
                       noteID: UUID, before: Note) async throws(SaveFailure) {
        _ = try await writeWithUndo(commit, plan: plan, noteID: noteID, before: before)
    }

    private func writeWithUndo(_ commit: NamingCommit, plan: @escaping @Sendable ([SavedVoice], Bool) -> NamingCommit,
                               noteID: UUID, before: Note) async throws(SaveFailure) -> [RecordedVoiceUndoOp] {
        let changes = commit.changes
        guard await library.commit(noteID, { $0.apply(changes) }) != nil else { throw SaveFailure(reason: .noteNotSaved) }
        guard let store else { return [] }
        let written: NamingCommit
        do {
            written = try await store.commit(plan)
        } catch {
            // The voices stay as they were, so the note's links go back too; the names typed stay.
            await library.commit(noteID) { $0.restoreVoiceLinks(from: before) }
            await refresh()
            throw SaveFailure(reason: .voiceNotSaved(error))
        }
        if written.changes != changes {
            let current = written.changes
            await library.commit(noteID) { $0.apply(current) }
        }
        await refresh()
        var scrubbedByVoice: [UUID: [ScrubbedVoiceLink]] = [:]
        for voice in written.forgotten {
            scrubbedByVoice[voice] = captureScrubbedLinks(for: voice)
            library.updateAll { $0.unlinkVoice(voice) }
            drafts?.mutateAll { $0.forgetting(voice) }
        }
        return written.voiceUndoOps.map { op in
            if case .undoUnenrol(let voiceID, _, _, true) = op {
                return RecordedVoiceUndoOp(op: op, scrubbedLinks: scrubbedByVoice[voiceID] ?? [])
            }
            return RecordedVoiceUndoOp(op: op)
        }
    }

    /// The speaker's latest print.
    private func print(noteID: UUID, speakerID: String) async -> SpeakerPrint? {
        try? await store?.prints(noteID: noteID).last { $0.speakerID == speakerID }
    }

    /// Enrolls a guided sample without making a Library meeting or exporting its private audio.
    public func enroll(name: String, print: SpeakerPrint, audio: URL, generation: Int) async throws {
        guard generation == settings.voicesGeneration, let store else { throw VoiceEnrollment.Invalid.ambiguous }
        try VoiceEnrollment.validate(print)
        try await store.enroll(name: name, print: print, audio: audio)
        await refresh()
    }

    // MARK: - Saved voices

    /// Renames a saved voice. Names already in notes stay, as on Android.
    public func rename(_ id: UUID, name: String) async -> VoiceEdit {
        guard let store else { return .readOnly }
        let outcome = await store.rename(id, name: name)
        await refresh()
        return outcome
    }

    /// Forgets one saved voice: the notes drop their links to it first, then the voice goes. Names stay.
    public func forget(_ id: UUID) async -> VoiceEdit {
        guard let store, !isReadOnly else { return .readOnly }
        library.updateAll { $0.unlinkVoice(id) }
        let outcome = await store.forget(id)
        await refresh()
        if outcome == .done { drafts?.mutateAll { $0.forgetting(id) } }
        return outcome
    }

    /// Forget everyone: the generation moves on first, so an analysis already running keeps nothing; then every voice
    /// and every print goes, and the notes drop their links. Names stay.
    public func forgetEveryone() async -> VoiceEdit {
        guard let store, snapshot.canForgetEveryone else { return .readOnly }
        settings.advanceVoicesGeneration()
        let outcome = await store.forgetEveryone()
        // A forget that failed keeps the voices, so the notes keep their links to them.
        if outcome == .done { library.updateAll { $0.reconcileVoices([]) } }
        await refresh()
        let generation = settings.voicesGeneration
        drafts?.mutateAll { $0.forgettingEveryone(generation: generation) }
        return outcome
    }

    // MARK: - Notes

    /// Shows another version of the transcript. Links to voices forgotten meanwhile are dropped; names stay. While the
    /// saved voices cannot be read the list is not known, so every link stays.
    public func selectTranscriptVersion(noteID: UUID, versionID: UUID) {
        let known: Set<UUID>? = isReadOnly ? nil : Set(savedVoices.map(\.id))
        library.update(noteID) { note in
            note.selectVersion(versionID)
            if let known { note.reconcileVoices(known) }
        }
    }

    public func addSpeaker(noteID: UUID, name: String) {
        let id = UUID().uuidString
        library.update(noteID) { $0.addSpeaker(id: id, name: name) }
    }

    /// Removes the note's voiceprints and its samples from saved voices, before the note is deleted for good. A voice
    /// left without samples is forgotten, and every note drops its links to it.
    public func removeEvidence(noteID: UUID) async throws {
        guard let store else { throw Unavailable() }
        let forgotten: [UUID]
        do {
            forgotten = try await store.removeEvidence(noteID: noteID)
        } catch is VoiceLibraryError {
            throw Unavailable()
        }
        await refresh()
        for voice in forgotten {
            library.updateAll { $0.unlinkVoice(voice) }
            drafts?.mutateAll { $0.forgetting(voice) }
        }
    }
}

/// The saved voices as the last refresh read them, with the Forget everyone generation then, for a job's live
/// matching on its inference thread.
public final class LiveVoices: Sendable {
    private let state = Mutex<(voices: [SavedVoice], generation: Int)>(([], 0))

    public init() {}

    func set(_ voices: [SavedVoice], generation: Int) { state.withLock { $0 = (voices, generation) } }

    /// The voices while `generation` is current; none once Forget everyone moved past it.
    public func voices(generation: Int) -> [SavedVoice] {
        state.withLock { $0.generation == generation ? $0.voices : [] }
    }
}

extension VoicesStore: VoiceEvidence {
    /// Newer, damaged or unreadable saved voices stop every permanent deletion, as before WP8's read-only voices.
    public var isReadable: Bool { !isReadOnly }
}
