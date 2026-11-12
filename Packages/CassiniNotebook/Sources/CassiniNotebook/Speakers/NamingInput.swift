import Foundation

/// Another speaker of the shown transcript, as the Merge sheet lists it.
public struct MergeTarget: Hashable, Sendable, Identifiable {
    public var speakerID: String
    public var name: String
    public var ordinal: Int
    public var speakingTime: Double
    public var id: String { speakerID }
    public init(speakerID: String, name: String, ordinal: Int, speakingTime: Double) {
        self.speakerID = speakerID; self.name = name; self.ordinal = ordinal; self.speakingTime = speakingTime
    }
}

/// What the Name a speaker sheet knows about one speaker when it opens.
///
/// - `label` is the speaker's name as stored; a placeholder ("Speaker 3") opens an empty field.
/// - `print` is the speaker's voiceprint from the note's analysis, if any.
/// - `match` is the speaker's link to a saved voice; `voices` the saved people, `voicesReadOnly` when they cannot be
///   changed, `voiceModelReady` whether recognising voices is installed.
/// - `mergeTargets` are the other speakers of the shown transcript; `versions` the version numbers a merge shows.
/// - `canSample` is false when the note's audio cannot play.
/// - `draft` is true while the job runs or is paused (naming open): the save goes to the draft's names, not the note.
///   A draft speaker has no `print` yet; `willHavePrint` says it gets one at the end of the job (the voiceprint model
///   is installed), and its `speakingTime` stands for the print's speech.
/// The version numbers a merge shows: "This adds version `added`; version `shown` stays available."
public struct MergeVersions: Hashable, Sendable {
    public var shown: Int
    public var added: Int
    public init(shown: Int, added: Int) { self.shown = shown; self.added = added }
}

public struct NamingInput: Hashable, Sendable {
    public var speakerID: String
    public var label: String
    public var ordinal: Int
    public var speakingTime: Double
    public var sample: SampleWindow?
    public var print: SpeakerPrint?
    public var match: VoiceMatchState
    public var voices: [SavedVoice]
    public var voicesReadOnly: Bool
    public var voiceModelReady: Bool
    /// The voiceprint model, for staleness when there is no print.
    public var currentModel: String
    public var mergeTargets: [MergeTarget]
    public var versions: MergeVersions
    public var canSample: Bool
    public var draft: Bool
    public var willHavePrint: Bool

    public init(speakerID: String, label: String, ordinal: Int = 0, speakingTime: Double = 0, sample: SampleWindow? = nil,
                print: SpeakerPrint? = nil, match: VoiceMatchState = .unmatched, voices: [SavedVoice] = [],
                voicesReadOnly: Bool = false, voiceModelReady: Bool = true,
                currentModel: String = VoiceprintModel.sha256,
                mergeTargets: [MergeTarget] = [], versions: MergeVersions = MergeVersions(shown: 1, added: 2), canSample: Bool = true,
                draft: Bool = false, willHavePrint: Bool = false) {
        self.speakerID = speakerID; self.label = label; self.ordinal = ordinal; self.speakingTime = speakingTime
        self.sample = sample; self.print = print; self.match = match; self.voices = voices
        self.voicesReadOnly = voicesReadOnly; self.voiceModelReady = voiceModelReady; self.currentModel = currentModel
        self.mergeTargets = mergeTargets; self.versions = versions; self.canSample = canSample
        self.draft = draft; self.willHavePrint = willHavePrint
    }

    /// The same named-first-speaking slots used by transcript headers, including unnamed merge targets.
    /// This is derived from the current labels so naming never leaves a stale avatar palette cached.
    public var speakerTints: [String: SpeakerTint] {
        let entries = [(speakerID, label, ordinal)] + mergeTargets.map { ($0.speakerID, $0.name, $0.ordinal) }
        let order = entries.sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 < $1.0 }.map { $0.0 }
        let labels = Dictionary(entries.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        return SpeakerTint.assign(order, labels: labels)
    }

    /// A print exists for the same-person question and the Remember switch.
    public var hasPrint: Bool { draft ? willHavePrint : print != nil }

    /// The stored name, or nil for a placeholder speaker.
    public var namedLabel: String? { DefaultLabels.isDefault(id: speakerID, label: label) ? nil : label }

    /// What the sheet needs about the note's speaker `speakerID`, with the speaker's latest `print` and the saved
    /// voices as they are now; nil when the note has no such speaker. Merge targets are the other speakers who say
    /// something. Remember works with a print of its own, or once the voiceprint model is installed (`voiceModelReady`).
    public static func of(_ note: Note, speakerID: String, print: SpeakerPrint?, voices: [SavedVoice],
                          voicesReadOnly: Bool, voiceModelReady: Bool) -> NamingInput? {
        guard let index = note.speakers?.firstIndex(where: { $0.id == speakerID }),
              let speaker = note.speakers?[index] else { return nil }
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
            sample: stat?.sample, print: print, match: speaker.match, voices: voices, voicesReadOnly: voicesReadOnly,
            voiceModelReady: print != nil || voiceModelReady,
            mergeTargets: targets, versions: MergeVersions(shown: versions.shown, added: versions.added),
            canSample: note.audio.isPlayable)
    }
}
