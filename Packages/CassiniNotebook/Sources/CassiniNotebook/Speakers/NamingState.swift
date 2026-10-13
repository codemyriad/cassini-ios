import Foundation

/// Why Remember this voice is off.
public enum RememberReason: Hashable, Sendable {
    /// "Recognising saved voices isn't installed yet."
    case noModel
    /// "Too little speech to remember this voice."
    case tooLittleSpeech
    /// The saved voices are newer, damaged or unreadable, so nothing can be remembered now.
    case readOnly
}

/// The Save name button.
public enum SaveState: Hashable, Sendable {
    case disabled
    case enabled
    /// Looks enabled, but a question must be answered first.
    case blockedByQuestion
}

/// The open sheet: the typed `name`, the saved voice it is bound to, the Remember switch, the answers given so far, and
/// the Merge step (nil while the Name sheet shows; a step without target for the list; a target for the
/// confirmation). The `initial` values are those at open, for the Save rule.
public struct NamingState: Hashable, Sendable {
    public var input: NamingInput
    public var name: String
    public var boundVoiceID: UUID?
    public var remember: Bool
    public var initialName: String
    public var initialBound: UUID?
    public var initialRemember: Bool
    public var showAll = false
    /// The normalised name the user answered "Someone else" to: the question stays closed for it.
    public var declinedSamePerson: String?
    /// The answer to "Also rename the saved voice?": true renames it, false keeps it (someone else).
    public var renameAnswer: Bool?
    public var merge: MergeStep?
}

/// The Merge sheet: `target` nil shows the list of speakers, a speaker id shows the confirmation.
public struct MergeStep: Hashable, Sendable {
    public var target: String?
    public init(target: String? = nil) { self.target = target }
}

/// What the sheet asks for.
public enum NamingEvent: Hashable, Sendable {
    case nameChanged(String)
    case pickVoice(UUID)
    case showAll
    /// "Same person" in the same-person question.
    case samePerson
    /// "Someone else" in the same-person question: Save makes a new voice.
    case someoneElse
    /// "Rename saved voice" in the rename-saved question.
    case renameSaved
    /// "Someone else" in the rename-saved question: the saved voice keeps its name, this speaker is someone else.
    case keepSaved
    /// "Not <name>?".
    case notThisPerson
    case rememberToggled(Bool)
    case playSample
    /// "Merge into…": the list of the other speakers.
    case mergeInto
    /// A row of the Merge list: the confirmation for that speaker.
    case mergeTarget(String)
    /// The confirmation's Cancel: back to the list.
    case cancelMerge
    /// Back from the Merge list to the Name sheet.
    case closeMerge
    case confirmMerge
    case save
    case cancel
}

/// What the app carries out for the sheet, in order.
public enum NamingEffect: Hashable, Sendable {
    /// Write `name` as the speaker's label.
    case relabel(speakerID: String, name: String)
    /// Enrol the speaker's print into `voiceID` (a new person when nil) called `name`; the speaker is then confirmed.
    case rememberVoice(speakerID: String, voiceID: UUID?, name: String)
    /// Rename the saved voice (the rename-saved question answered yes). Names already in notes stay.
    case renameVoice(UUID, name: String)
    /// Drop an automatic match to a voice the speaker is no longer called.
    case clearMatch(speakerID: String)
    /// Take back the confirmed sample of the speaker: it was confirmed as someone else.
    case unenrol(speakerID: String)
    /// "Not <name>": the voice is rejected for the speaker; `unenrol` takes a confirmed sample back first, and
    /// `restorePlaceholder` returns a label equal to that name to "Speaker N".
    case reject(speakerID: String, voiceID: UUID, voiceName: String, unenrol: Bool, restorePlaceholder: Bool)
    /// Merge `source` into `target`; this adds a version.
    case merge(source: String, target: String)
    case playRange(SampleWindow)
    /// Save was pressed with a question open: focus the question and say "Answer the question above first".
    case focusQuestion
    case close
}

/// The sheet after an event (`state` nil once it closed) and the effects to carry out.
public struct NamingResult: Hashable, Sendable {
    public var state: NamingState?
    public var effects: [NamingEffect]
    public init(_ state: NamingState?, _ effects: [NamingEffect] = []) { self.state = state; self.effects = effects }

    /// The effects that change the note or the saved voices, in order: the sheet stays while they are written and
    /// closes once they are (`NamingCommit`).
    public var writes: [NamingEffect] { effects.filter(\.isWrite) }
}

extension NamingEffect {
    /// Whether the effect changes the note or the saved voices, rather than the sheet (a sample, the question's focus,
    /// closing).
    public var isWrite: Bool {
        switch self {
        case .playRange, .focusQuestion, .close: false
        case .relabel, .rememberVoice, .renameVoice, .clearMatch, .unenrol, .reject, .merge: true
        }
    }
}

/// The Name a speaker sheet as the screen shows it.
public struct NameSheetUI: Hashable, Sendable {
    public struct VoiceRow: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var likely: Bool
    }

    public var speakerID: String
    public var label: String
    public var placeholderNumber: Int?
    public var speakingTime: Double
    public var canSample: Bool
    public var name: String
    public var voices: [VoiceRow]
    /// "Show all" is offered.
    public var showAll: Bool
    /// "Saved voices, closest first" rather than "Saved voices".
    public var ranked: Bool
    /// The voice of "“Anna Ricci” is already a saved voice. Is this the same person?".
    public var samePerson: String?
    /// The voice of "This voice is saved as “Anna Ricci”. Also rename the saved voice?".
    public var renameSaved: String?
    /// The voice of "Not Luca?".
    public var notName: String?
    public var remember: Bool
    public var rememberEnabled: Bool
    public var rememberReason: RememberReason?
    public var canMerge: Bool
    public var save: SaveState
}

/// The Merge sheet.
public struct MergeUI: Hashable, Sendable {
    public var sourceID: String
    public var source: String
    public var targets: [MergeTarget]
    public var confirm: MergeTarget?
    public var shownVersion: Int
    public var addedVersion: Int
}
