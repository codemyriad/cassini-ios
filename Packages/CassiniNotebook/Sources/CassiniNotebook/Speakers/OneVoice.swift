import Foundation

/// The speaker of words that no speaker step told apart (D59 as amended after Android R9): one speaker for every
/// passage, with an id new to the run, labelled "Speaker 1" in the user's language when the words are produced, as the
/// speaker step labels its own speakers (D47). The id is `<prefix>1`, where `prefix` is the run's speaker id prefix
/// (`WindowSpeakers.freshPrefix()`, kept in the checkpoint for a resume): the id the run's diarizer would give its
/// first speaker, as Android writes `diar_<run>_1`. A fixed id would let a later run inherit an earlier one's label,
/// name and saved voice (D56). A speaker step replaces it with its own speakers. A passage without a speaker id is one
/// the user set to no speaker ("Unknown speaker", exported as `unassigned`).
extension NoteSpeaker {
    /// The one voice of the run whose speaker ids begin with `prefix`, labelled "Speaker 1" in `language`.
    public static func oneVoice(prefix: String, language: String = DefaultLabels.appLanguage) -> NoteSpeaker {
        NoteSpeaker(id: prefix + "1", name: DefaultLabels.placeholder(1, language: language))
    }
}

extension Array where Element == NoteSpeaker {
    /// Whether these speakers hold nothing a speaker step that told voices apart or the user gave: none (a note with no
    /// words, or as an older build stored it), or a single speaker still under its placeholder, linked to no saved voice
    /// and excluding none. A speaker step that found a single unnamed voice gives the same shape and counts too.
    public var isOneVoice: Bool {
        guard let only = first else { return true }
        return count == 1 && DefaultLabels.isDefault(id: only.id, label: only.name) && only.match == .unmatched
            && only.excludedVoiceIDs.isEmpty
    }
}

extension Note {
    /// `segments` with every passage spoken by `voice`.
    public static func oneVoice(_ segments: [TranscriptSegment], _ voice: NoteSpeaker) -> [TranscriptSegment] {
        segments.map { segment in
            var voiced = segment
            voiced.speakerID = voice.id
            voiced.speaker = voice.name
            return voiced
        }
    }
}
