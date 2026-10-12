import Foundation

/// What the effects of the Name a speaker sheet (or of a suggestion card) change: the saved voices and the note's
/// speakers, worked out before anything is written. The app writes the note first and the voices after it, so a note
/// that cannot be saved leaves no voice behind.
public struct NamingCommit: Hashable, Sendable {
    /// The saved voices after the effects.
    public var voices: [SavedVoice]
    /// The changes to the note's speakers.
    public var changes: [SpeakerChange]
    /// Voices left without a sample: they are forgotten, so every note drops its links to them.
    public var forgotten: [UUID]
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
            case .rememberVoice(let id, let voiceID, let name):
                guard let print, print.speechSeconds >= VoiceLibrary.minimumRememberSeconds else {
                    commit.refused = .noPrint
                    continue
                }
                let score = voiceID.flatMap { id in commit.voices.first { $0.id == id }?.score(print) } ?? 1
                let enrolled = VoiceCodec.enrol(commit.voices, voiceID: voiceID, name: name, noteID: noteID, print: print,
                                                newID: newVoiceID)
                commit.voices = enrolled.voices
                commit.changes.append(.match(speakerID: id, .confirmed(voice: enrolled.voice.id, score: score)))
            case .renameVoice(let voiceID, let name):
                guard let index = commit.voices.firstIndex(where: { $0.id == voiceID }) else { continue }
                commit.voices[index].name = name
            case .clearMatch(let id):
                commit.changes.append(.match(speakerID: id, .unmatched))
            case .unenrol(let id):
                commit.unenrol(speaker, noteID: noteID)
                commit.changes.append(.match(speakerID: id, .unmatched))
            case .reject(let id, let voiceID, _, let unenrol, let restore):
                if unenrol { commit.unenrol(speaker, noteID: noteID) }
                commit.changes.append(.reject(speakerID: id, voiceID: voiceID, restorePlaceholder: restore))
            case .merge(let source, let target):
                commit.changes.append(.merge(source: source, target: target, stamp: stamp))
            case .playRange, .focusQuestion, .close:
                break
            }
        }
        commit.voicesChanged = commit.voices != voices
        commit.changes += commit.forgotten.map(SpeakerChange.unlinkVoice)
        if commit.changesVoices && voicesReadOnly { commit.refused = .readOnly }
        return commit
    }

    /// Takes back the speaker's confirmed sample; a voice left without samples is forgotten.
    private mutating func unenrol(_ speaker: NoteSpeaker, noteID: UUID) {
        guard case .confirmed(let voiceID, _) = speaker.match else { return }
        let result = VoiceCodec.unenrol(voices, voiceID: voiceID, noteID: noteID, speakerID: speaker.id)
        voices = result.voices
        if result.outcome == .forgotten { forgotten.append(voiceID) }
    }
}
