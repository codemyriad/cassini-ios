import Foundation

/// The timed JSON export (iOS only): the note's metadata and transcript, without anything that links its speakers to
/// saved voices.
public enum JSONExport {
    /// `note` with `version` as its transcript when one is given, pretty-printed with sorted keys and ISO 8601 dates.
    public static func data(_ note: Note, version: TranscriptVersion? = nil) throws -> Data {
        var copy = note
        if let version {
            copy.transcript = version.segments; copy.speakers = version.speakers; copy.selectedVersionID = version.id
        }
        copy.speakers = copy.speakers.map(publicSpeakers)
        copy.versions = copy.versions?.map { value in
            var version = value; version.speakers = publicSpeakers(version.speakers); return version
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    private static func publicSpeakers(_ speakers: [NoteSpeaker]) -> [NoteSpeaker] {
        speakers.map { value in var speaker = value; speaker.match = .unmatched; speaker.excludedVoiceIDs = []; return speaker }
    }
}
