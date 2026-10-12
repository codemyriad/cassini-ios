import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Saved voices and the speakers of each note: the app's side of `VoiceStore`. Naming effects are worked out by
/// `NamingCommit` and written note first, voices after; a voice write that fails puts the note's links back.
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

    /// Saved voices as the screen lists them.
    var summaries: [SavedVoiceSummary] {
        SavedVoiceList.summaries(savedVoices, notes: library.notes, model: settings.speakerModelIdentity)
    }

    func voice(_ id: UUID?) -> SavedVoice? { id.flatMap { id in savedVoices.first { $0.id == id } } }

    /// The "Is this Luca?" cards of a note.
    func suggestions(for note: Note) -> [SpeakerSuggestion] { SpeakerSuggestions.of(note, voices: savedVoices) }

    /// Opens the private voice files. False when they cannot be used as they are; they are kept.
    @discardableResult func load() async -> Bool {
        guard let root = library.root else { return false }
        let clock = clock
        do {
            store = try VoiceStore(root: root, now: { clock.now })
        } catch {
            return false
        }
        await refresh()
        return !snapshot.isReadOnly
    }

    func refresh() async {
        guard let store else { return }
        snapshot = await store.snapshot()
    }

    /// Drops the voiceprints of notes that no longer exist, at launch.
    func sweepOrphans() async throws {
        guard let store, library.loadFailure == nil else { return }
        try await store.sweepOrphans(keeping: Set(library.notes.map(\.id)))
        await refresh()
    }

    // MARK: - Speaker analysis

    /// Puts a finished analysis into the note: speakers of their own, attributed passages, and matches to saved voices.
    /// Voiceprints are kept, and voices matched, only while `generation` is still current: an analysis that began
    /// before Forget everyone keeps nothing. Rejected voices stay rejected for the speakers that overlap the old ones.
    func applySpeakerAnalysis(_ analysis: SpeakerAnalysis, to id: UUID, generation: Int) async throws {
        guard let note = library.note(id), note.trashedAt == nil else { return }
        if let model = analysis.prints.first?.model { settings.speakerModelIdentity = model }
        let (turns, prints) = SpeakerAttribution.namespaced(turns: analysis.turns, prints: analysis.prints,
                                                             prefix: UUID().uuidString + "_")
        if generation == settings.voicesGeneration, let store {
            // A note's prints are kept even if the saved voices can't be changed now; the note keeps working without.
            try? await store.appendPrints(prints, noteID: id)
        }
        let matches = generation == settings.voicesGeneration
            ? VoiceMatcher.match(prints: prints, voices: activeVoices(excluding: id), excluded: note.carriedExclusions(for: turns))
            : [:]
        let names = Dictionary(savedVoices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let autoName = settings.automaticallyNameVoices
        let stamp = VersionStamp(date: clock.now)
        let saved = await library.commit(id) { note in
            guard note.trashedAt == nil else { return }
            note.applySpeakerAnalysis(turns: turns, matches: matches, voiceNames: names, autoName: autoName, stamp: stamp)
        }
        guard saved != nil else { throw CocoaError(.fileWriteUnknown) }
        await refresh()
    }

    /// The saved voices with the samples of `noteID` and of notes in Recently Deleted left out.
    private func activeVoices(excluding noteID: UUID) -> [SavedVoice] {
        savedVoices.map { voice in
            var copy = voice
            copy.samples.removeAll { $0.noteID == noteID || library.note($0.noteID)?.trashedAt != nil }
            return copy
        }
    }

    // MARK: - Naming

    /// What the Name a speaker sheet needs about the speaker; nil when the note or the speaker is gone.
    func namingInput(noteID: UUID, speakerID: String) async -> NamingInput? {
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
        guard let note = library.note(noteID), let speaker = note.speaker(speakerID) else { return }
        let print = await print(noteID: noteID, speakerID: speakerID)
        let commit = NamingCommit.plan(effects, noteID: noteID, speaker: speaker, print: print, voices: savedVoices,
                                       voicesReadOnly: isReadOnly, stamp: VersionStamp(date: clock.now))
        switch commit.refused {
        case .readOnly?: throw SaveFailure(message: SpeakersCopy.voicesReadOnly)
        case .noPrint?: throw SaveFailure(message: SpeakersCopy.tooLittleSpeech)
        case nil: try await write(commit, noteID: noteID, before: note)
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

    private func write(_ commit: NamingCommit, noteID: UUID, before: Note) async throws(SaveFailure) {
        let changes = commit.changes
        guard await library.commit(noteID, { $0.apply(changes) }) != nil else { throw SaveFailure(message: SpeakersCopy.noteNotSaved) }
        guard commit.changesVoices, let store else { return }
        do {
            try await store.save(commit.voices)
        } catch {
            // The voices stay as they were, so the note's links go back too; the names typed stay.
            let links = Dictionary((before.speakers ?? []).map { ($0.id, ($0.match, $0.excludedVoiceIDs)) }, uniquingKeysWith: { a, _ in a })
            await library.commit(noteID) { note in
                for index in (note.speakers ?? []).indices {
                    guard let id = note.speakers?[index].id, let link = links[id] else { continue }
                    note.speakers?[index].match = link.0
                    note.speakers?[index].excludedVoiceIDs = link.1
                }
            }
            await refresh()
            throw SaveFailure(message: SpeakersCopy.voiceNotSaved(error.localizedDescription))
        }
        await refresh()
        for voice in commit.forgotten { library.updateAll { $0.unlinkVoice(voice) } }
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
        library.updateAll { $0.reconcileVoices([]) }
        await refresh()
        return outcome
    }

    // MARK: - Notes

    /// Shows another version of the transcript. Links to voices forgotten meanwhile are dropped; names stay.
    func selectTranscriptVersion(noteID: UUID, versionID: UUID) {
        let known = Set(savedVoices.map(\.id))
        library.update(noteID) { note in
            note.selectVersion(versionID)
            note.reconcileVoices(known)
        }
    }

    func addSpeaker(noteID: UUID, name: String) {
        let id = UUID().uuidString
        library.update(noteID) { $0.addSpeaker(id: id, name: name) }
    }

    /// Removes the note's voiceprints and its samples from saved voices, before the note is deleted for good.
    func removeEvidence(noteID: UUID) async throws {
        guard let store else { throw Unavailable(message: SpeakersCopy.evidenceUnavailable) }
        do {
            try await store.removeEvidence(noteID: noteID)
        } catch is VoiceLibraryError {
            throw Unavailable(message: SpeakersCopy.evidenceUnavailable)
        }
        await refresh()
    }
}
