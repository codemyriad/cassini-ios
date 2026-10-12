import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Saved voices and the speakers of each note.
@MainActor @Observable final class VoicesStore {
    /// The saved voices could not be read; their files are kept.
    struct Unavailable: Error {
        let message: String
    }

    /// Why a speaker could not be saved, shown in the speaker sheet.
    struct SaveFailure: Error {
        let message: String
    }

    private(set) var savedVoices: [SavedVoice] = []
    @ObservationIgnored private(set) var voiceLibrary: VoiceLibrary?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let errors: ErrorPresenter

    init(library: LibraryStore, settings: SettingsStore, errors: ErrorPresenter) {
        self.library = library; self.settings = settings; self.errors = errors
    }

    /// Opens the private voice files. False when they could not be read.
    @discardableResult func load() -> Bool {
        guard let root = library.root else { return false }
        do {
            let voices = try VoiceLibrary(root: root)
            voiceLibrary = voices
            savedVoices = voices.voices
            return true
        } catch {
            return false
        }
    }

    var hasEvidence: Bool { voiceLibrary?.hasEvidence == true }

    func voice(_ id: UUID?) -> SavedVoice? { id.flatMap { id in savedVoices.first { $0.id == id } } }

    func speakerPrint(noteID: UUID, speakerID: String) -> SpeakerPrint? {
        try? voiceLibrary?.prints(noteID: noteID).last { $0.speakerID == speakerID }
    }

    /// Puts a finished analysis into the note: fresh speaker ids, attributed passages, and matches to saved voices.
    /// Voiceprints are kept only while `generation` is still current.
    func applySpeakerAnalysis(_ analysis: SpeakerAnalysis, to id: UUID, generation: Int) async throws {
        guard var note = library.note(id), note.trashedAt == nil else { return }
        let keepsEvidence = generation == settings.voicesGeneration
        note.saveCurrentVersion(name: "Before speaker analysis")
        if let model = analysis.prints.first?.model { settings.speakerModelIdentity = model }
        // A new analysis gets a fresh namespace: old versions keep their original identities.
        let prefix = UUID().uuidString + "_"
        let turns = analysis.turns.map { SpeakerTurn(speakerID: prefix + $0.speakerID, start: $0.start, end: $0.end) }
        let prints = analysis.prints.map { value in var copy = value; copy.speakerID = prefix + value.speakerID; return copy }
        var seen: Set<String> = []
        let ids = turns.sorted { $0.start < $1.start }.compactMap { seen.insert($0.speakerID).inserted ? $0.speakerID : nil }
        note.speakers = ids.enumerated().map { NoteSpeaker(id: $0.element, name: "Speaker \($0.offset + 1)") }
        note.transcript = SpeakerAttribution.assign(note.transcript, turns: turns)
        let activeVoices = savedVoices.map { voice in
            var copy = voice
            copy.samples.removeAll { sample in library.note(sample.noteID)?.trashedAt != nil || sample.noteID == id }
            return copy
        }
        let matches = keepsEvidence ? VoiceMatcher.match(prints: prints, voices: activeVoices) : [:]
        for index in (note.speakers ?? []).indices {
            guard let speaker = note.speakers?[index], let match = matches[speaker.id], let voice = voice(match.voiceID) else { continue }
            // Automatic naming is opt-in, uses a high threshold and a rival margin, and never enrols evidence by itself.
            if settings.automaticallyNameVoices && match.automatic {
                note.speakers?[index].name = voice.name
                note.speakers?[index].match = .auto(voice: voice.id, score: match.score)
            } else {
                note.speakers?[index].match = .suggested(voice: voice.id, score: match.score)
            }
        }
        note.refreshSpeakerLabels(); note.selectedVersionID = nil
        note.saveCurrentVersion(name: "Speaker analysis")
        note.speakerAnalysisFailure = ids.isEmpty ? .empty : nil
        if keepsEvidence, let voiceLibrary {
            let existing = try voiceLibrary.prints(noteID: id)
            try voiceLibrary.savePrints(existing + prints, noteID: id)
        }
        let analyzed = note
        guard await library.commit(id, { $0 = analyzed }) != nil else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Names a speaker, optionally linking or remembering its voice.
    func saveSpeaker(noteID: UUID, speakerID: String, name: String, voiceID: UUID?, remember: Bool, renameSaved: Bool) throws(SaveFailure) {
        guard let voiceLibrary else { throw SaveFailure(message: "Saved voice storage is unavailable. Your voice files have been preserved.") }
        guard var note = library.note(noteID), let index = note.speakers?.firstIndex(where: { $0.id == speakerID }) else { return }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !clean.isEmpty else { return }
        if let voiceID, let other = note.speakers?.first(where: { $0.id != speakerID && $0.linkedVoiceID == voiceID }) {
            throw SaveFailure(message: "This saved voice is already assigned to \(other.name). Merge these speakers if they are the same person.")
        }
        var voices = savedVoices
        var link = voiceID
        if remember {
            guard let print = speakerPrint(noteID: noteID, speakerID: speakerID), print.speechSeconds >= 6 else {
                throw SaveFailure(message: "At least six seconds of isolated speech are needed to remember this voice.")
            }
            if let id = link, let voiceIndex = voices.firstIndex(where: { $0.id == id }) {
                voices[voiceIndex].samples.removeAll { $0.noteID == noteID && $0.print.speakerID == speakerID }
                voices[voiceIndex].samples.append(VoiceSample(noteID: noteID, print: print))
            } else {
                let voice = SavedVoice(name: clean, samples: [VoiceSample(noteID: noteID, print: print)])
                voices.append(voice); link = voice.id
            }
        }
        if renameSaved, let link, let voiceIndex = voices.firstIndex(where: { $0.id == link }) { voices[voiceIndex].name = clean }
        note.renameSpeaker(speakerID, name: clean)
        let previous = note.speakers?[index].match
        note.speakers?[index].match = link.map { .confirmed(voice: $0, score: previous?.voiceID == $0 ? previous?.score ?? 0 : 0) } ?? .unmatched
        do {
            try voiceLibrary.save(voices); savedVoices = voices
        } catch {
            throw SaveFailure(message: "Could not save voice: \(error.localizedDescription)")
        }
        let named = note
        library.update(noteID) { $0 = named }
        if renameSaved, let link { renameVoice(link, name: clean) }
    }

    func rejectVoice(noteID: UUID, speakerID: String, voiceID: UUID) {
        library.update(noteID) { note in
            guard let index = note.speakers?.firstIndex(where: { $0.id == speakerID }), let speaker = note.speakers?[index] else { return }
            note.speakers?[index].excludedVoiceIDs.append(voiceID)
            if speaker.linkedVoiceID == voiceID { note.speakers?[index].name = "Speaker \(index + 1)" }
            note.speakers?[index].match = .rejected(voice: voiceID, score: speaker.match.score ?? 0)
            note.refreshSpeakerLabels()
        }
    }

    func renameVoice(_ id: UUID, name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !clean.isEmpty, let index = savedVoices.firstIndex(where: { $0.id == id }), let voiceLibrary else { return }
        var voices = savedVoices; voices[index].name = clean
        do {
            try voiceLibrary.save(voices); savedVoices = voices
            library.updateAll { note in
                for speaker in note.speakers ?? [] where speaker.linkedVoiceID == id { note.renameSpeaker(speaker.id, name: clean) }
            }
        } catch { errors.present(error.localizedDescription) }
    }

    func forgetAllVoices() {
        guard let voiceLibrary else { errors.present("Saved voice storage is unavailable."); return }
        settings.advanceVoicesGeneration()
        do {
            try voiceLibrary.forgetAll(); savedVoices = voiceLibrary.voices
            library.updateAll { note in
                for index in (note.speakers ?? []).indices where note.speakers?[index].match.isRejection == false {
                    note.speakers?[index].match = .unmatched
                }
            }
        } catch {
            savedVoices = voiceLibrary.voices
            errors.present("Some voice data could not be removed: \(error.localizedDescription). Try Forget all voice data again.")
        }
    }

    func forgetVoice(_ id: UUID) {
        guard let voiceLibrary else { return }
        do {
            try voiceLibrary.save(savedVoices.filter { $0.id != id }); savedVoices = voiceLibrary.voices
            library.updateAll { note in
                for index in (note.speakers ?? []).indices {
                    if let match = note.speakers?[index].match, match.voiceID == id, !match.isRejection {
                        note.speakers?[index].match = .unmatched
                    }
                }
            }
        } catch { errors.present(error.localizedDescription) }
    }

    func selectTranscriptVersion(noteID: UUID, versionID: UUID) {
        let known = Dictionary(uniqueKeysWithValues: savedVoices.map { ($0.id, $0.name) })
        library.update(noteID) { note in
            note.selectVersion(versionID)
            for index in (note.speakers ?? []).indices {
                guard let speaker = note.speakers?[index], let voiceID = speaker.match.voiceID, !speaker.match.isRejection else { continue }
                if let name = known[voiceID] {
                    if speaker.linkedVoiceID != nil { note.speakers?[index].name = name }
                } else {
                    note.speakers?[index].match = .unmatched
                }
            }
            note.refreshSpeakerLabels()
        }
    }

    func addSpeaker(noteID: UUID, name: String) {
        let speaker = NoteSpeaker(id: UUID().uuidString, name: name)
        library.update(noteID) { note in note.speakers = (note.speakers ?? []) + [speaker] }
    }

    /// Removes the note's voiceprints and its samples from saved voices, before the note is deleted for good.
    func removeEvidence(noteID: UUID) throws {
        guard let voiceLibrary else {
            throw Unavailable(message: "Saved voice storage could not be read. Restore access before permanent deletion so voice samples can be removed safely.")
        }
        try voiceLibrary.removeEvidence(noteID: noteID)
        savedVoices = voiceLibrary.voices
    }
}
