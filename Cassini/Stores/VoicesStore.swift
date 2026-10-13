import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Saved voices and the speakers of each note: the app's side of `VoiceStore`. Naming effects are worked out by
/// `NamingCommit` and written note first, voices after; the voice side is worked out again on the `VoiceStore` actor
/// against the voices as they are then, so overlapping edits keep each other. A voice write that fails puts the note's
/// links back.
@MainActor @Observable final class VoicesStore {
    /// The saved voices could not be read; their files are kept.
    struct Unavailable: Error {
        let message: String
    }

    /// Why a speaker could not be saved, shown in the speaker sheet.
    struct SaveFailure: Error {
        let message: String
    }

    private(set) var snapshot = VoiceSnapshot()
    /// The private voice files could not be opened at launch.
    private(set) var loadFailed = false
    @ObservationIgnored private(set) var store: VoiceStore?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private let clock: any AppClock

    init(library: LibraryStore, settings: SettingsStore, errors: ErrorPresenter, clock: any AppClock) {
        self.library = library; self.settings = settings; self.errors = errors; self.clock = clock
    }

    var savedVoices: [SavedVoice] { snapshot.voices }
    /// The saved voices cannot be changed: newer, damaged or unreadable, or the private folder could not be opened.
    var isReadOnly: Bool { store == nil || snapshot.isReadOnly }
    var hasEvidence: Bool { snapshot.hasEvidence }
    /// "Saved voices can't be read": the files could not be opened, were written by a newer Cassini or cannot be read
    /// now. A damaged list is not: Saved voices offers to start it again.
    var isUnavailable: Bool { loadFailed || snapshot.problem == .newer || snapshot.problem == .unreadable }
    /// Whether Saved voices offers Forget all voice data with no person listed: there are prints to delete, or the list
    /// is damaged and only Forget everyone starts it again.
    var offersForgetAllData: Bool { snapshot.canForgetEveryone && (hasEvidence || snapshot.problem == .damaged) }

    /// Saved voices as the screen lists them.
    var summaries: [SavedVoiceSummary] {
        SavedVoiceList.summaries(savedVoices, notes: library.notes, model: settings.speakerModelIdentity)
    }

    func voice(_ id: UUID?) -> SavedVoice? { id.flatMap { id in savedVoices.first { $0.id == id } } }

    /// The "Is this Luca?" cards of a note.
    func suggestions(for note: Note) -> [SpeakerSuggestion] { SpeakerSuggestions.of(note, voices: savedVoices) }

    /// Opens the private voice files, off the main actor. False when they cannot be used as they are; they are kept.
    @discardableResult func load() async -> Bool {
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

    func refresh() async {
        guard let store else { return }
        snapshot = await store.snapshot()
    }

    /// Reads the saved voices again when the last read failed for a passing reason, before they are used.
    private func retryUnreadable() async {
        if snapshot.problem == .unreadable { await refresh() }
    }

    /// Drops the voiceprints of notes that no longer exist, at launch. A note folder that could not be read keeps its
    /// prints (`VoiceLibrary.sweepOrphans`).
    func sweepOrphans() async throws {
        guard let store, library.loadFailure == nil else { return }
        try await store.sweepOrphans(keeping: Set(library.notes.map(\.id)))
        await refresh()
    }

    // MARK: - Speaker analysis

    /// Puts a finished analysis into the note: speakers of their own, attributed passages, and matches to saved voices
    /// and to the note's own named speakers (`AnalysisMatches`), so their names carry over. Voiceprints are kept, and
    /// voices matched, only while `generation` is still current: an analysis that began before Forget everyone keeps
    /// nothing.
    func applySpeakerAnalysis(_ analysis: SpeakerAnalysis, to id: UUID, generation: Int) async throws {
        await retryUnreadable()
        guard let note = library.note(id), note.trashedAt == nil else { return }
        if let model = analysis.prints.first?.model { settings.speakerModelIdentity = model }
        let (turns, prints) = SpeakerAttribution.namespaced(turns: analysis.turns, prints: analysis.prints,
                                                             prefix: UUID().uuidString + "_")
        var matching = AnalysisMatches()
        if generation == settings.voicesGeneration, let store {
            let earlier = (try? await store.prints(noteID: id)) ?? []
            // A note's prints are kept even if the saved voices can't be changed now; the note keeps working without.
            try? await store.appendPrints(prints, noteID: id)
            matching = AnalysisMatches.of(note, turns: turns, prints: prints, savedVoices: savedVoices, earlierPrints: earlier,
                                          trashed: Set(library.notes.filter { $0.trashedAt != nil }.map(\.id)))
        }
        let autoName = settings.automaticallyNameVoices
        let stamp = VersionStamp(date: clock.now)
        let saved = await library.commit(id) { [matching] note in
            guard note.trashedAt == nil else { return }
            matching.apply(to: &note, turns: turns, autoName: autoName, stamp: stamp)
        }
        guard saved != nil else { throw CocoaError(.fileWriteUnknown) }
        await refresh()
    }

    // MARK: - Naming

    /// What the Name a speaker sheet needs about the speaker; nil when the note or the speaker is gone.
    func namingInput(noteID: UUID, speakerID: String) async -> NamingInput? {
        await retryUnreadable()
        guard let note = library.note(noteID), let index = note.speakers?.firstIndex(where: { $0.id == speakerID }),
              let speaker = note.speakers?[index] else { return nil }
        let print = await print(noteID: noteID, speakerID: speakerID)
        let stats = SpeakerStats.of(note.transcript)
        let stat = stats.first { $0.speakerID == speakerID }
        let targets = stats.filter { $0.speakerID != speakerID && $0.wordCount > 0 }.compactMap { other -> MergeTarget? in
            note.speaker(other.speakerID).map {
                MergeTarget(speakerID: $0.id, name: $0.name, ordinal: other.ordinal, speakingTime: other.speakingTime)
            }
        }
        let versions = note.mergeVersionNumbers
        return NamingInput(
            speakerID: speakerID, label: speaker.name, ordinal: stat?.ordinal ?? index, speakingTime: stat?.speakingTime ?? 0,
            sample: stat?.sample, print: print, match: speaker.match, voices: savedVoices, voicesReadOnly: isReadOnly,
            voiceModelReady: print != nil || settings.speakerModelIdentity != nil, currentModel: settings.speakerModelIdentity,
            mergeTargets: targets, versions: MergeVersions(shown: versions.shown, added: versions.added),
            canSample: note.audio.isPlayable)
    }

    /// Carries out the sheet's effects for one speaker: the note first, then the saved voices.
    func perform(_ effects: [NamingEffect], noteID: UUID, speakerID: String) async throws(SaveFailure) {
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
        case .readOnly?: throw SaveFailure(message: SpeakersCopy.voicesReadOnly)
        case .noPrint?: throw SaveFailure(message: SpeakersCopy.tooLittleSpeech)
        case nil: try await write(commit, plan: plan, noteID: noteID, before: note)
        }
    }

    /// "Yes, Luca": names the speaker after the voice and confirms it, remembering the speaker's print in it.
    func accept(_ suggestion: SpeakerSuggestion, noteID: UUID) async throws(SaveFailure) {
        try await perform([.relabel(speakerID: suggestion.speakerID, name: suggestion.voiceName),
                           .rememberVoice(speakerID: suggestion.speakerID, voiceID: suggestion.voiceID, name: suggestion.voiceName)],
                          noteID: noteID, speakerID: suggestion.speakerID)
    }

    /// "Not Luca": the voice is never offered for this speaker again.
    func reject(_ suggestion: SpeakerSuggestion, noteID: UUID) async throws(SaveFailure) {
        try await perform([.reject(speakerID: suggestion.speakerID, voiceID: suggestion.voiceID, voiceName: suggestion.voiceName,
                                   unenrol: false, restorePlaceholder: false)],
                          noteID: noteID, speakerID: suggestion.speakerID)
    }

    /// Writes the note's side of `commit`, then the voices: `plan` runs again on the `VoiceStore` actor against the
    /// voices as they are then. When that gives the note other changes (a voice forgotten meanwhile), they follow; the
    /// notes drop their links to forgotten voices only once the voices are written.
    private func write(_ commit: NamingCommit, plan: @escaping @Sendable ([SavedVoice], Bool) -> NamingCommit,
                       noteID: UUID, before: Note) async throws(SaveFailure) {
        let changes = commit.changes
        guard await library.commit(noteID, { $0.apply(changes) }) != nil else { throw SaveFailure(message: SpeakersCopy.noteNotSaved) }
        guard let store else { return }
        let written: NamingCommit
        do {
            written = try await store.commit(plan)
        } catch {
            // The voices stay as they were, so the note's links go back too; the names typed stay.
            await library.commit(noteID) { $0.restoreVoiceLinks(from: before) }
            await refresh()
            throw SaveFailure(message: SpeakersCopy.voiceNotSaved(FailureReason.of(error)))
        }
        if written.changes != changes {
            let current = written.changes
            await library.commit(noteID) { $0.apply(current) }
        }
        await refresh()
        for voice in written.forgotten { library.updateAll { $0.unlinkVoice(voice) } }
    }

    private func print(noteID: UUID, speakerID: String) async -> SpeakerPrint? {
        try? await store?.prints(noteID: noteID).last { $0.speakerID == speakerID }
    }

    // MARK: - Saved voices

    /// Renames a saved voice. Names already in notes stay, as on Android.
    func rename(_ id: UUID, name: String) async -> VoiceEdit {
        guard let store else { return .readOnly }
        let outcome = await store.rename(id, name: name)
        await refresh()
        return outcome
    }

    /// Forgets one saved voice: the notes drop their links to it first, then the voice goes. Names stay.
    func forget(_ id: UUID) async -> VoiceEdit {
        guard let store, !isReadOnly else { return .readOnly }
        library.updateAll { $0.unlinkVoice(id) }
        let outcome = await store.forget(id)
        await refresh()
        return outcome
    }

    /// Forget everyone: the generation moves on first, so an analysis already running keeps nothing; then every voice
    /// and every print goes, and the notes drop their links. Names stay.
    func forgetEveryone() async -> VoiceEdit {
        guard let store, snapshot.canForgetEveryone else { return .readOnly }
        settings.advanceVoicesGeneration()
        let outcome = await store.forgetEveryone()
        // A forget that failed keeps the voices, so the notes keep their links to them.
        if outcome == .done { library.updateAll { $0.reconcileVoices([]) } }
        await refresh()
        return outcome
    }

    // MARK: - Notes

    /// Shows another version of the transcript. Links to voices forgotten meanwhile are dropped; names stay. While the
    /// saved voices cannot be read the list is not known, so every link stays.
    func selectTranscriptVersion(noteID: UUID, versionID: UUID) {
        let known: Set<UUID>? = isReadOnly ? nil : Set(savedVoices.map(\.id))
        library.update(noteID) { note in
            note.selectVersion(versionID)
            if let known { note.reconcileVoices(known) }
        }
    }

    func addSpeaker(noteID: UUID, name: String) {
        let id = UUID().uuidString
        library.update(noteID) { $0.addSpeaker(id: id, name: name) }
    }

    /// Removes the note's voiceprints and its samples from saved voices, before the note is deleted for good. A voice
    /// left without samples is forgotten, and every note drops its links to it.
    func removeEvidence(noteID: UUID) async throws {
        guard let store else { throw Unavailable(message: SpeakersCopy.evidenceUnavailable) }
        let forgotten: [UUID]
        do {
            forgotten = try await store.removeEvidence(noteID: noteID)
        } catch is VoiceLibraryError {
            throw Unavailable(message: SpeakersCopy.evidenceUnavailable)
        }
        await refresh()
        for voice in forgotten { library.updateAll { $0.unlinkVoice(voice) } }
    }
}
