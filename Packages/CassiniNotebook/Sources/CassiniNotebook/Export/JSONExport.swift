import Foundation

/// The timed JSON export (iOS only): the note's metadata and transcript, without anything that links its speakers to
/// saved voices.
public enum JSONExport {
    /// `note` with `version` as its transcript when one is given (with that version's words, speakers and language),
    /// pretty-printed with sorted keys and ISO 8601 dates.
    public static func data(_ note: Note, version: TranscriptVersion? = nil) throws -> Data {
        var copy = note
        if let version {
            copy.transcript = version.segments; copy.speakers = version.speakers; copy.language = version.language
            copy.selectedVersionID = version.id
        }
        copy.speakers = copy.speakers.map(publicSpeakers)
        copy.versions = copy.versions?.map { value in
            var version = value; version.speakers = publicSpeakers(version.speakers); return version
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // D53.1: stars belong to this device's Library, including for the legacy JSON export.
        let data = try encoder.encode(copy)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "isFavorite")
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func publicSpeakers(_ speakers: [NoteSpeaker]) -> [NoteSpeaker] {
        speakers.map { value in var speaker = value; speaker.match = .unmatched; speaker.excludedVoiceIDs = []; return speaker }
    }
}
