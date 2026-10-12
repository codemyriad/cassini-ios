import Foundation

/// A voice file whose `version` this Cassini cannot read. A `newer` file is kept as it is and never written.
public struct UnsupportedVoiceFileVersion: Error, Hashable, Sendable {
    public var found: Int
    public var supported: Int
    public var newer: Bool { found > supported }
}

/// The `version` of a voice file, read before the rest.
private struct VoiceFileVersion: Decodable {
    var version: Int
}

/// `voices.json`, version 1: `{"version": 1, "voices": [SavedVoice]}`. Before the version field the file was a bare
/// array of voices, which still reads. Also the enrolment arithmetic, without the file.
public enum VoiceCodec {
    public static let version = 1

    private struct Envelope: Codable {
        var version: Int
        var voices: [SavedVoice]
    }

    /// Throws `UnsupportedVoiceFileVersion` for another version, and a decoding error for anything unparseable.
    public static func decode(_ data: Data) throws -> [SavedVoice] {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([SavedVoice].self, from: data) { return legacy }
        let found = try decoder.decode(VoiceFileVersion.self, from: data).version
        guard found == version else { throw UnsupportedVoiceFileVersion(found: found, supported: version) }
        return try decoder.decode(Envelope.self, from: data).voices
    }

    public static func encode(_ voices: [SavedVoice]) throws -> Data {
        try JSONEncoder().encode(Envelope(version: version, voices: voices))
    }

    /// `voices` with `print` of the note confirmed as `voiceID`, called `name`; a new person with `newID` when
    /// `voiceID` is nil or unknown. A sample of the same note and speaker is replaced, never counted twice.
    public static func enrol(_ voices: [SavedVoice], voiceID: UUID?, name: String, noteID: UUID, print: SpeakerPrint,
                             newID: UUID) -> (voices: [SavedVoice], voice: SavedVoice) {
        var result = voices
        let sample = VoiceSample(noteID: noteID, print: print)
        if let index = result.firstIndex(where: { $0.id == voiceID }) {
            result[index].name = name
            result[index].samples.removeAll { $0.noteID == noteID && $0.print.speakerID == print.speakerID }
            result[index].samples.append(sample)
            return (result, result[index])
        }
        let voice = SavedVoice(id: newID, name: name, samples: [sample])
        result.append(voice)
        return (result, voice)
    }

    public enum UnenrolOutcome: Hashable, Sendable {
        /// One sample was taken back; the person is still saved.
        case unenrolled
        /// The person had only this sample and is forgotten everywhere.
        case forgotten
        /// There was no such sample.
        case nothingToUndo
    }

    /// `voices` with the sample of `speakerID` in the note taken back from `voiceID`. A voice left without samples is
    /// removed: the caller forgets it in every note.
    public static func unenrol(_ voices: [SavedVoice], voiceID: UUID, noteID: UUID, speakerID: String)
        -> (voices: [SavedVoice], outcome: UnenrolOutcome) {
        guard let index = voices.firstIndex(where: { $0.id == voiceID }),
              let sample = voices[index].samples.firstIndex(where: { $0.noteID == noteID && $0.print.speakerID == speakerID })
        else { return (voices, .nothingToUndo) }
        var result = voices
        result[index].samples.remove(at: sample)
        guard result[index].samples.isEmpty else { return (result, .unenrolled) }
        result.remove(at: index)
        return (result, .forgotten)
    }
}

/// `PrivateVoices/<note id>.json`, version 1: `{"version": 1, "prints": [SpeakerPrint]}`, the prints of every speaker
/// analysis of one note. Before the version field the file was a bare array of prints, which still reads. Matches are
/// not here: on iOS they are part of the note's speakers.
public enum NoteVoiceCodec {
    public static let version = 1

    private struct Envelope: Codable {
        var version: Int
        var prints: [SpeakerPrint]
    }

    /// The file name of a note's prints.
    public static func fileName(_ noteID: UUID) -> String { noteID.uuidString + ".json" }

    /// The note whose prints a file name holds; nil for any other name, so nothing else in the folder is touched.
    public static func noteID(fileName: String) -> UUID? {
        guard fileName.hasSuffix(".json"), let id = UUID(uuidString: String(fileName.dropLast(5))),
              fileName == self.fileName(id) else { return nil }
        return id
    }

    /// Throws `UnsupportedVoiceFileVersion` for another version, and a decoding error for anything unparseable.
    public static func decode(_ data: Data) throws -> [SpeakerPrint] {
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([SpeakerPrint].self, from: data) { return legacy }
        let found = try decoder.decode(VoiceFileVersion.self, from: data).version
        guard found == version else { throw UnsupportedVoiceFileVersion(found: found, supported: version) }
        return try decoder.decode(Envelope.self, from: data).prints
    }

    public static func encode(_ prints: [SpeakerPrint]) throws -> Data {
        try JSONEncoder().encode(Envelope(version: version, prints: prints))
    }
}
