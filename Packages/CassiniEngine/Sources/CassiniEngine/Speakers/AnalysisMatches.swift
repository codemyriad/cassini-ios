import Foundation
import CassiniNotebook

/// What a finished speaker analysis of a note is matched with: the saved voices, without the samples of notes in
/// Recently Deleted and without the note's own samples except for the voices its named speakers are linked to, and the
/// note's other named speakers as note-local voices, so that their names carry over to the new version (Android's
/// note-local voices; Android matches with every saved sample). A voice remembered from this note alone therefore
/// still matches its speaker. Voices rejected for the speakers that overlap the old ones stay rejected.
public struct AnalysisMatches: Hashable, Sendable {
    /// The best voice for each analysed speaker.
    public var matches: [String: VoiceMatch]
    /// The names of every voice matched with, saved and note-local.
    public var voiceNames: [UUID: String]
    /// The note-local voices among them.
    public var localVoices: Set<UUID>
    /// The saved voices the note's named speakers were linked to, with their links (`Note.carriedVoiceLinks`).
    public var carriedLinks: [UUID: VoiceMatchState]

    public init(matches: [String: VoiceMatch] = [:], voiceNames: [UUID: String] = [:], localVoices: Set<UUID> = [],
                carriedLinks: [UUID: VoiceMatchState] = [:]) {
        self.matches = matches; self.voiceNames = voiceNames; self.localVoices = localVoices; self.carriedLinks = carriedLinks
    }

    /// `prints` and `turns` are the new analysis's; `earlierPrints` the prints the note had before it; `trashed` the
    /// notes in Recently Deleted.
    public static func of(_ note: Note, turns: [SpeakerTurn], prints: [SpeakerPrint], savedVoices: [SavedVoice],
                          earlierPrints: [SpeakerPrint], trashed: Set<UUID>) -> AnalysisMatches {
        let links = note.carriedVoiceLinks
        let saved = savedVoices.map { voice in
            var copy = voice
            let ownKept = links[voice.id] != nil
            copy.samples.removeAll { ($0.noteID == note.id && !ownKept) || trashed.contains($0.noteID) }
            return copy
        }
        let local = note.localVoices(prints: earlierPrints, savedVoiceIDs: Set(savedVoices.map(\.id)))
        let voices = saved + local
        return AnalysisMatches(
            matches: VoiceMatcher.match(prints: prints, voices: voices, excluded: note.carriedExclusions(for: turns)),
            voiceNames: Dictionary(voices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            localVoices: Set(local.map(\.id)), carriedLinks: links)
    }

    /// The note with the analysis put into it (`Note.applySpeakerAnalysis`).
    public func apply(to note: inout Note, turns: [SpeakerTurn], autoName: Bool, stamp: VersionStamp) {
        note.applySpeakerAnalysis(turns: turns, matches: matches, voiceNames: voiceNames, localVoices: localVoices,
                                  carriedLinks: carriedLinks, autoName: autoName, stamp: stamp)
    }
}
