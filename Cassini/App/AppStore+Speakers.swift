import Foundation
import CassiniNotebook
import CassiniInference

extension AppStore {
    func purgeExpiredTrash(now: Date = Date()) {
        for note in notes where note.trashedAt.map({ TrashPolicy.daysLeft(since: $0, now: now) == 0 }) == true {
            deletePermanently(note.id)
        }
    }
    func emptyTrash() { for note in notes where note.trashedAt != nil { deletePermanently(note.id) } }
    func applySpeakerAnalysis(_ analysis: SpeakerAnalysis, to id: UUID, allowEvidence: Bool = true) throws {
        guard var note = note(id), note.trashedAt == nil else { return }
        note.saveCurrentVersion(name: "Before speaker analysis")
        // New analysis gets a fresh namespace: old versions keep their original identities.
        if let model = analysis.prints.first?.model { speakerModelIdentity = model }
        let prefix = UUID().uuidString + "_"
        let turns = analysis.turns.map { SpeakerTurn(speakerID: prefix + $0.speakerID, start: $0.start, end: $0.end) }
        let prints = analysis.prints.map { value in var copy = value; copy.speakerID = prefix + value.speakerID; return copy }
        var seen: Set<String> = []
        let ids = turns.sorted { $0.start < $1.start }.compactMap { seen.insert($0.speakerID).inserted ? $0.speakerID : nil }
        note.speakers = ids.enumerated().map { NoteSpeaker(id: $0.element, name: "Speaker \($0.offset + 1)") }
        note.transcript = SpeakerAttribution.assign(note.transcript, turns: turns)
        let activeVoices = savedVoices.map { voice in
            var copy = voice
            copy.samples.removeAll { sample in self.note(sample.noteID)?.trashedAt != nil || sample.noteID == id }
            return copy
        }
        let matches = allowEvidence ? VoiceMatcher.match(prints: prints, voices: activeVoices) : [:]
        for index in (note.speakers ?? []).indices {
            guard let speaker = note.speakers?[index], let match = matches[speaker.id], let voice = savedVoices.first(where: { $0.id == match.voiceID }) else { continue }
            // Auto naming is opt-in, uses a high threshold and rival margin, and never enrolls evidence by itself.
            note.speakers?[index].suggestedVoiceID = voice.id
            if automaticallyNameVoices && match.automatic {
                note.speakers?[index].name = voice.name; note.speakers?[index].voiceID = voice.id
            }
        }
        note.refreshSpeakerLabels(); note.selectedVersionID = nil
        note.saveCurrentVersion(name: "Speaker analysis")
        note.speakerAnalysisMessage = ids.isEmpty ? "No speakers were detected. You can assign passages manually." : nil
        if allowEvidence {
            let existing = try voiceLibrary?.prints(noteID: id) ?? []
            try voiceLibrary?.savePrints(existing + prints, noteID: id)
        }
        guard update(id, { $0 = note }) else { throw CocoaError(.fileWriteUnknown) }
    }
    func speakerPrint(noteID: UUID, speakerID: String) -> SpeakerPrint? {
        try? voiceLibrary?.prints(noteID: noteID).last { $0.speakerID == speakerID }
    }
    @discardableResult func saveSpeaker(noteID: UUID, speakerID: String, name: String, voiceID: UUID?, remember: Bool, renameSaved: Bool) -> Bool {
        guard let library = voiceLibrary else { errorMessage = "Saved voice storage is unavailable. Your voice files have been preserved."; return false }
        guard var note = note(noteID), let index = note.speakers?.firstIndex(where: { $0.id == speakerID }) else { return false }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !clean.isEmpty else { return false }
        if let voiceID, let other = note.speakers?.first(where: { $0.id != speakerID && $0.voiceID == voiceID }) {
            errorMessage = "This saved voice is already assigned to \(other.name). Merge these speakers if they are the same person."; return false
        }
        var voices = savedVoices
        var link = voiceID
        if remember {
            guard let print = speakerPrint(noteID: noteID, speakerID: speakerID), print.speechSeconds >= 6 else {
                errorMessage = "At least six seconds of isolated speech are needed to remember this voice."; return false
            }
            if let id = link, let vi = voices.firstIndex(where: { $0.id == id }) {
                voices[vi].samples.removeAll { $0.noteID == noteID && $0.print.speakerID == speakerID }
                voices[vi].samples.append(VoiceSample(noteID: noteID, print: print))
            } else {
                let voice = SavedVoice(name: clean, samples: [VoiceSample(noteID: noteID, print: print)])
                voices.append(voice); link = voice.id
            }
        }
        if renameSaved, let link, let vi = voices.firstIndex(where: { $0.id == link }) { voices[vi].name = clean }
        note.renameSpeaker(speakerID, name: clean)
        note.speakers?[index].voiceID = link; note.speakers?[index].suggestedVoiceID = nil
        do {
            try library.save(voices); savedVoices = voices
            guard update(noteID, { $0 = note }) else { return false }
            if renameSaved, let link { renameVoice(link, name: clean) }
            return true
        } catch { errorMessage = "Could not save voice: \(error.localizedDescription)"; return false }
    }
    func rejectVoice(noteID: UUID, speakerID: String, voiceID: UUID) {
        update(noteID) { note in
            guard let index = note.speakers?.firstIndex(where: { $0.id == speakerID }) else { return }
            note.speakers?[index].excludedVoiceIDs.append(voiceID)
            if note.speakers?[index].voiceID == voiceID { note.speakers?[index].name = "Speaker \(index + 1)" }
            note.speakers?[index].suggestedVoiceID = nil; note.speakers?[index].voiceID = nil
            note.refreshSpeakerLabels()
        }
    }
    func renameVoice(_ id: UUID, name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !clean.isEmpty, let index = savedVoices.firstIndex(where: { $0.id == id }), let library = voiceLibrary else { return }
        var voices = savedVoices; voices[index].name = clean
        do {
            try library.save(voices); savedVoices = voices
            for note in notes where note.speakers?.contains(where: { $0.voiceID == id }) == true {
                update(note.id) { copy in for speaker in copy.speakers ?? [] where speaker.voiceID == id { copy.renameSpeaker(speaker.id, name: clean) } }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func forgetAllVoices() {
        guard let library = voiceLibrary else { errorMessage = "Saved voice storage is unavailable."; return }
        voiceGeneration += 1
        do {
            try library.forgetAll(); savedVoices = library.voices
            for note in notes {
                update(note.id) { copy in
                    for index in (copy.speakers ?? []).indices {
                        copy.speakers?[index].voiceID = nil; copy.speakers?[index].suggestedVoiceID = nil
                    }
                }
            }
        } catch { savedVoices = library.voices; errorMessage = "Some voice data could not be removed: \(error.localizedDescription). Try Forget all voice data again." }
    }
    func forgetVoice(_ id: UUID) {
        guard let library = voiceLibrary else { return }
        do {
            try library.save(savedVoices.filter { $0.id != id }); savedVoices = library.voices
            for note in notes {
                update(note.id) { copy in
                    for index in (copy.speakers ?? []).indices {
                        if copy.speakers?[index].voiceID == id { copy.speakers?[index].voiceID = nil }
                        if copy.speakers?[index].suggestedVoiceID == id { copy.speakers?[index].suggestedVoiceID = nil }
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectTranscriptVersion(noteID: UUID, versionID: UUID) {
        update(noteID) { note in
            note.selectVersion(versionID)
            for index in (note.speakers ?? []).indices {
                if let id = note.speakers?[index].voiceID {
                    if let voice = savedVoices.first(where: { $0.id == id }) { note.speakers?[index].name = voice.name }
                    else { note.speakers?[index].voiceID = nil }
                }
                if let id = note.speakers?[index].suggestedVoiceID, !savedVoices.contains(where: { $0.id == id }) { note.speakers?[index].suggestedVoiceID = nil }
            }
            note.refreshSpeakerLabels()
        }
    }
    func assignSpeaker(noteID: UUID, segmentID: UUID, speakerID: String?) {
        update(noteID) { note in
            guard let index = note.transcript.firstIndex(where: { $0.id == segmentID }) else { return }
            note.transcript[index].speakerID = speakerID; note.transcript[index].speaker = nil
            note.refreshSpeakerLabels()
        }
    }
    func addSpeaker(noteID: UUID, name: String) {
        update(noteID) { note in
            var speakers = note.speakers ?? []; speakers.append(NoteSpeaker(id: UUID().uuidString, name: name)); note.speakers = speakers
        }
    }
}
