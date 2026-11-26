import Foundation

/// What the effects of the Name a speaker sheet (or of a suggestion card) change: the saved voices and the note's
/// speakers, worked out before anything is written. The app writes the note first and the voices after it, so a note
/// that cannot be saved leaves no voice behind.
public struct NamingCommit: Hashable, Sendable {
    /// One inverse voice operation recorded in effect order during `plan`, to be replayed in strict reverse order
    /// on Undo or batch rollback.
    public enum VoiceUndoOp: Hashable, Sendable {
        /// Reverses `.rememberVoice`: removes the enrolled sample (and the voice if left empty), restores any replaced
        /// sample and previous voice name.
        case undoEnrol(voiceID: UUID, noteID: UUID, speakerID: String, previousName: String?, replacedSample: VoiceSample?)
        /// Reverses `.unenrol` / `.reject(unenrol: true)`: restores the removed sample to `voiceID`, recreating the
        /// voice from `fallbackVoice` if it was forgotten.
        case undoUnenrol(voiceID: UUID, sample: VoiceSample, fallbackVoice: SavedVoice, forgotten: Bool)
        /// Reverses `.renameVoice`: restores `previousName` on `voiceID`.
        case undoRename(voiceID: UUID, previousName: String)
    }

    /// The saved voices after the effects.
    public var voices: [SavedVoice]
    /// The changes to the note's speakers.
    public var changes: [SpeakerChange]
    /// Voices left without a sample: they are forgotten, so every note drops its links to them once the voices are
    /// written (`Note.unlinkVoice`). They are not in `changes`, so a voice write that fails leaves the links alone.
    public var forgotten: [UUID]
    /// Inverse voice operations in effect order; replay in strict reverse order to undo or roll back.
    public var voiceUndoOps: [VoiceUndoOp] = []
    /// The voice changes need a print the note no longer has, or voices that cannot be changed now.
    public var refused: Refusal?

    public enum Refusal: Hashable, Sendable {
        /// Remembering needs the speaker's print with enough speech.
        case noPrint
        /// The saved voices cannot be changed now.
        case readOnly
    }

    public var changesVoices: Bool { !forgotten.isEmpty || voicesChanged }
    private var voicesChanged = false

    /// Works out `effects` for `speaker` of note `noteID`, whose print is `print`. `newVoiceID` is the id of a person
    /// the effects create, and `stamp` the versions a merge adds; both are made by the caller so that the note change
    /// can run again with the same result.
    public static func plan(_ effects: [NamingEffect], noteID: UUID, speaker: NoteSpeaker, print: SpeakerPrint?,
                            voices: [SavedVoice], voicesReadOnly: Bool, newVoiceID: UUID = UUID(),
                            stamp: VersionStamp = VersionStamp(date: Date())) -> NamingCommit {
        var commit = NamingCommit(voices: voices, changes: [], forgotten: [])
        for effect in effects {
            switch effect {
            case .relabel(let id, let name):
                commit.changes.append(.rename(speakerID: id, name: name))
            case .setBackground(let id, let background):
                commit.changes.append(.setBackground(speakerID: id, background: background))
            case .rememberVoice(let id, let voiceID, let name):
                guard let print, print.speechSeconds >= VoiceLibrary.minimumRememberSeconds else {
                    commit.refused = .noPrint
                    continue
                }
                let existing = voiceID.flatMap { vid in commit.voices.first { $0.id == vid } }
                let previousName = existing?.name
                let replacedSample = existing?.samples.first { $0.noteID == noteID && $0.print.speakerID == print.speakerID }
                let score = existing?.score(print) ?? 1
                let enrolled = VoiceCodec.enrol(commit.voices, voiceID: voiceID, name: name, noteID: noteID, print: print,
                                                newID: newVoiceID)
                commit.voices = enrolled.voices
                commit.voiceUndoOps.append(.undoEnrol(voiceID: enrolled.voice.id, noteID: noteID, speakerID: print.speakerID,
                                                      previousName: previousName, replacedSample: replacedSample))
                commit.changes.append(.match(speakerID: id, .confirmed(voice: enrolled.voice.id, score: score)))
            case .renameVoice(let voiceID, let name):
                guard let index = commit.voices.firstIndex(where: { $0.id == voiceID }) else { continue }
                let previousName = commit.voices[index].name
                commit.voices[index].name = name
                if previousName != name {
                    commit.voiceUndoOps.append(.undoRename(voiceID: voiceID, previousName: previousName))
                }
            case .clearMatch(let id):
                commit.changes.append(.match(speakerID: id, .unmatched))
            case .unenrol(let id):
                commit.unenrol(speaker, noteID: noteID)
                commit.changes.append(.match(speakerID: id, .unmatched))
            case .reject(_, _, _, _, _, draft: true):
                break // The draft's reject, carried out by the draft path.
            case .reject(let id, let voiceID, _, let unenrol, let restore, _):
                if unenrol { commit.unenrol(speaker, noteID: noteID) }
                commit.changes.append(.reject(speakerID: id, voiceID: voiceID, restorePlaceholder: restore))
            case .merge(let source, let target):
                commit.changes.append(.merge(source: source, target: target, stamp: stamp))
            case .playRange, .focusQuestion, .close:
                break
            case .mergeDraft, .draftName:
                break // A draft's names, not the sealed note: the draft path carries these out.
            }
        }
        commit.voicesChanged = commit.voices != voices
        if commit.changesVoices && voicesReadOnly { commit.refused = .readOnly }
        return commit
    }

    /// Takes back the speaker's confirmed sample; a voice left without samples is forgotten.
    private mutating func unenrol(_ speaker: NoteSpeaker, noteID: UUID) {
        guard case .confirmed(let voiceID, _) = speaker.match else { return }
        let previousVoice = voices.first { $0.id == voiceID }
        let removedSample = previousVoice?.samples.first { $0.noteID == noteID && $0.print.speakerID == speaker.id }
        let result = VoiceCodec.unenrol(voices, voiceID: voiceID, noteID: noteID, speakerID: speaker.id)
        voices = result.voices
        if result.outcome != .nothingToUndo, let previousVoice, let removedSample {
            voiceUndoOps.append(.undoUnenrol(voiceID: voiceID, sample: removedSample, fallbackVoice: previousVoice,
                                             forgotten: result.outcome == .forgotten))
        }
        if result.outcome == .forgotten { forgotten.append(voiceID) }
    }

    /// Applies one inverse voice operation to `voices` and returns the inverse ops (in effect order; replay in reverse
    /// order) needed to compensate only this operation against a later voice state without overwriting concurrent edits.
    @discardableResult
    public static func applyInverse(_ op: VoiceUndoOp, to voices: inout [SavedVoice]) -> [VoiceUndoOp] {
        switch op {
        case .undoEnrol(let voiceID, let noteID, let speakerID, let previousName, let replacedSample):
            guard let index = voices.firstIndex(where: { $0.id == voiceID }) else { return [] }
            let currentVoice = voices[index]
            let currentName = currentVoice.name
            let removedSample = currentVoice.samples.first { $0.noteID == noteID && $0.print.speakerID == speakerID }
            voices[index].samples.removeAll { $0.noteID == noteID && $0.print.speakerID == speakerID }
            if let replacedSample { voices[index].samples.append(replacedSample) }
            if let previousName { voices[index].name = previousName }
            let removedVoice = voices[index].samples.isEmpty
            if removedVoice { voices.remove(at: index) }
            var inverse: [VoiceUndoOp] = []
            if let previousName, previousName != currentName {
                inverse.append(.undoRename(voiceID: voiceID, previousName: currentName))
            }
            if let replacedSample {
                inverse.append(.undoEnrol(voiceID: voiceID, noteID: replacedSample.noteID,
                                          speakerID: replacedSample.print.speakerID,
                                          previousName: nil, replacedSample: nil))
            }
            if let removedSample {
                inverse.append(.undoUnenrol(voiceID: voiceID, sample: removedSample,
                                            fallbackVoice: currentVoice, forgotten: removedVoice))
            }
            return inverse
        case .undoUnenrol(let voiceID, let sample, let fallbackVoice, _):
            let replacedSample: VoiceSample?
            if let index = voices.firstIndex(where: { $0.id == voiceID }) {
                replacedSample = voices[index].samples.first {
                    $0.noteID == sample.noteID && $0.print.speakerID == sample.print.speakerID
                }
                voices[index].samples.removeAll {
                    $0.noteID == sample.noteID && $0.print.speakerID == sample.print.speakerID
                }
                voices[index].samples.append(sample)
            } else {
                replacedSample = nil
                var restored = fallbackVoice
                restored.samples = [sample]
                voices.append(restored)
            }
            return [.undoEnrol(voiceID: voiceID, noteID: sample.noteID, speakerID: sample.print.speakerID,
                               previousName: nil, replacedSample: replacedSample)]
        case .undoRename(let voiceID, let previousName):
            guard let index = voices.firstIndex(where: { $0.id == voiceID }) else { return [] }
            let currentName = voices[index].name
            voices[index].name = previousName
            return currentName == previousName ? [] : [.undoRename(voiceID: voiceID, previousName: currentName)]
        }
    }
}
