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
    /// The model of the current analyses, for staleness when there is no print.
    public var currentModel: String?
    public var mergeTargets: [MergeTarget]
    public var versions: MergeVersions
    public var canSample: Bool

    public init(speakerID: String, label: String, ordinal: Int = 0, speakingTime: Double = 0, sample: SampleWindow? = nil,
                print: SpeakerPrint? = nil, match: VoiceMatchState = .unmatched, voices: [SavedVoice] = [],
                voicesReadOnly: Bool = false, voiceModelReady: Bool = true, currentModel: String? = nil,
                mergeTargets: [MergeTarget] = [], versions: MergeVersions = MergeVersions(shown: 1, added: 2), canSample: Bool = true) {
        self.speakerID = speakerID; self.label = label; self.ordinal = ordinal; self.speakingTime = speakingTime
        self.sample = sample; self.print = print; self.match = match; self.voices = voices
        self.voicesReadOnly = voicesReadOnly; self.voiceModelReady = voiceModelReady; self.currentModel = currentModel
        self.mergeTargets = mergeTargets; self.versions = versions; self.canSample = canSample
    }

    /// The stored name, or nil for a placeholder speaker.
    public var namedLabel: String? { DefaultLabels.isDefault(id: speakerID, label: label) ? nil : label }
}

/// Why Remember this voice is off.
public enum RememberReason: Hashable, Sendable {
    /// "Recognising saved voices isn't installed yet."
    case noModel
    /// "Too little speech to remember this voice."
    case tooLittleSpeech
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

/// The pure reducer of the Name a speaker sheet: events in, sheet state and effects out. The app keeps one
/// `NamingState` while the sheet is open, shows `ui` and `mergeUI`, and carries out the effects (`NamingCommit`).
///
/// The save follows Android's `rememberVoice`: a confirmed voice that is no longer this speaker is unenrolled, a
/// stale automatic match is cleared, then the print is enrolled into the bound or a new voice. iOS has no draft
/// naming while a job runs, so only Android's sealed paths exist.
public enum SpeakerNaming {
    /// The longest name the field takes.
    public static let maxName = Limits.nameMaxLength
    /// Remember needs at least this much isolated speech (iOS threshold; Android uses 4 s).
    public static let minimumRememberSeconds = VoiceLibrary.minimumRememberSeconds
    /// Rows of saved voices before "Show all".
    public static let visibleVoices = 3

    /// The sheet at open: the field holds the label (empty for a placeholder), bound to a matching saved voice.
    public static func open(_ input: NamingInput) -> NamingState {
        let name = input.namedLabel ?? ""
        let voice = linkedVoice(input)
        // A confirmed voice is this speaker even when the label was written differently; an automatic one only by name.
        let bound = voice.flatMap { voice -> UUID? in
            if case .confirmed = input.match { return voice.id }
            return NameMatch.same(voice.name, name) ? voice.id : nil
        }
        let remember = rememberReason(input) == nil && !input.voicesReadOnly
        return NamingState(input: input, name: name, boundVoiceID: bound, remember: remember, initialName: name,
                           initialBound: bound, initialRemember: remember)
    }

    public static func reduce(_ state: NamingState, _ event: NamingEvent) -> NamingResult {
        var next = state
        switch event {
        case .nameChanged(let text): return NamingResult(nameChanged(state, text))
        case .pickVoice(let id): return NamingResult(pick(state, id))
        case .showAll: next.showAll = true
        case .samePerson: return NamingResult(samePerson(state).map { pick(state, $0.id) } ?? state)
        case .someoneElse: next.declinedSamePerson = NameMatch.normalise(state.name)
        case .renameSaved: next.renameAnswer = true; next.remember = rememberable(state)
        case .keepSaved: next.renameAnswer = false
        case .notThisPerson: return notThisPerson(state)
        case .rememberToggled(let on): next.remember = on && rememberable(state)
        case .playSample: return NamingResult(state, playSample(state))
        case .mergeInto: if canMerge(state) { next.merge = MergeStep() }
        case .mergeTarget(let id):
            if state.merge != nil, state.input.mergeTargets.contains(where: { $0.speakerID == id }) { next.merge = MergeStep(target: id) }
        case .cancelMerge: if state.merge != nil { next.merge = MergeStep() }
        case .closeMerge: next.merge = nil
        case .confirmMerge: return confirmMerge(state)
        case .save: return save(state)
        case .cancel: return NamingResult(nil, [.close])
        }
        return NamingResult(next)
    }

    // MARK: - The sheet as the screen shows it

    public static func ui(_ state: NamingState) -> NameSheetUI {
        let input = state.input
        let ranked = rankedVoices(input)
        let shown = state.showAll ? ranked : Array(ranked.prefix(visibleVoices))
        let reason = rememberReason(input)
        return NameSheetUI(
            speakerID: input.speakerID, label: input.label, placeholderNumber: DefaultLabels.placeholderNumber(input.label),
            speakingTime: input.speakingTime, canSample: input.sample != nil && input.canSample, name: state.name,
            voices: shown.map { NameSheetUI.VoiceRow(id: $0.voice.id, name: $0.voice.name, likely: $0.likely) },
            showAll: !state.showAll && ranked.count > visibleVoices, ranked: input.print != nil,
            samePerson: samePerson(state)?.name, renameSaved: renameQuestion(state)?.name, notName: notName(input)?.name,
            remember: state.remember && reason == nil, rememberEnabled: reason == nil && !input.voicesReadOnly,
            rememberReason: reason, canMerge: canMerge(state), save: saveState(state))
    }

    /// The Merge sheet, or nil while the Name sheet shows.
    public static func mergeUI(_ state: NamingState) -> MergeUI? {
        guard let step = state.merge else { return nil }
        let targets = state.input.mergeTargets
        return MergeUI(sourceID: state.input.speakerID, source: state.input.label, targets: targets,
                       confirm: step.target.flatMap { id in targets.first { $0.speakerID == id } },
                       shownVersion: state.input.versions.shown, addedVersion: state.input.versions.added)
    }

    /// Disabled only for an empty name, or when nothing changed and the speaker is already confirmed: an automatic,
    /// suggested or unmatched speaker can still Save its name, which confirms it.
    public static func saveState(_ state: NamingState) -> SaveState {
        let trimmed = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var confirmed = false
        if case .confirmed = state.input.match { confirmed = true }
        let unchanged = trimmed == state.initialName.trimmingCharacters(in: .whitespacesAndNewlines)
            && state.boundVoiceID == state.initialBound
            && effectiveRemember(state) == (state.initialRemember && rememberReason(state.input) == nil)
            && confirmed
        if trimmed.isEmpty || unchanged { return .disabled }
        if samePerson(state) != nil || renameQuestion(state) != nil { return .blockedByQuestion }
        return .enabled
    }

    // MARK: - Questions

    /// The same-person question: Remember is on, no voice is bound, a print exists, the name was not answered
    /// "Someone else", and the typed name is a saved voice's full name or first word. The best scored one.
    public static func samePerson(_ state: NamingState) -> SavedVoice? {
        let typed = NameMatch.normalise(state.name)
        guard effectiveRemember(state), state.boundVoiceID == nil, state.input.print != nil,
              !typed.isEmpty, typed != state.declinedSamePerson else { return nil }
        return NameMatch.samePerson(state.name, voices: state.input.voices, scores: NameMatch.scores(state.input.print, voices: state.input.voices))
    }

    /// The rename-saved question: the speaker is confirmed as voice V, the user edited the name and it differs from
    /// V's name, with no voice bound and no same-person question open.
    public static func renameQuestion(_ state: NamingState) -> SavedVoice? {
        guard let confirmed = confirmedVoice(state.input) else { return nil }
        let edited = !NameMatch.same(state.name, state.initialName)
        let open = state.renameAnswer == nil && state.boundVoiceID == nil
            && !state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard edited, open, !NameMatch.same(confirmed.name, state.name), samePerson(state) == nil else { return nil }
        return confirmed
    }

    /// The voice of "Not <name>?": an automatic or confirmed match to a saved voice.
    public static func notName(_ input: NamingInput) -> SavedVoice? { linkedVoice(input) }

    /// Why Remember is off, or nil when it can be on.
    public static func rememberReason(_ input: NamingInput) -> RememberReason? {
        if !input.voiceModelReady { return .noModel }
        guard let print = input.print, print.speechSeconds >= minimumRememberSeconds else { return .tooLittleSpeech }
        return nil
    }

    // MARK: - Events

    private static func nameChanged(_ state: NamingState, _ text: String) -> NamingState {
        var next = state
        next.name = String(text.prefix(maxName))
        next.boundVoiceID = state.boundVoiceID.flatMap { id in
            state.input.voices.contains { $0.id == id && NameMatch.same($0.name, next.name) } ? id : nil
        }
        if !NameMatch.same(next.name, state.name) { next.renameAnswer = nil }
        return next
    }

    private static func pick(_ state: NamingState, _ voiceID: UUID) -> NamingState {
        guard let voice = state.input.voices.first(where: { $0.id == voiceID }) else { return state }
        var next = state
        next.name = String(voice.name.prefix(maxName))
        next.boundVoiceID = voice.id
        next.renameAnswer = nil
        return next
    }

    private static func notThisPerson(_ state: NamingState) -> NamingResult {
        let input = state.input
        guard let voice = notName(input) else { return NamingResult(state) }
        var confirmed = false
        if case .confirmed = input.match { confirmed = true }
        let reject = NamingEffect.reject(speakerID: input.speakerID, voiceID: voice.id, voiceName: voice.name,
                                         unenrol: confirmed,
                                         restorePlaceholder: input.namedLabel.map { NameMatch.same($0, voice.name) } ?? false)
        return NamingResult(nil, [reject, .close])
    }

    private static func playSample(_ state: NamingState) -> [NamingEffect] {
        guard state.input.canSample, let sample = state.input.sample else { return [] }
        return [.playRange(sample)]
    }

    private static func confirmMerge(_ state: NamingState) -> NamingResult {
        guard let id = state.merge?.target, let target = state.input.mergeTargets.first(where: { $0.speakerID == id })
        else { return NamingResult(state) }
        return NamingResult(nil, [.merge(source: state.input.speakerID, target: target.speakerID), .close])
    }

    private static func save(_ state: NamingState) -> NamingResult {
        switch saveState(state) {
        case .disabled: return NamingResult(state)
        case .blockedByQuestion: return NamingResult(state, [.focusQuestion])
        case .enabled: return NamingResult(nil, sealedSave(state) + [.close])
        }
    }

    /// Relabel, then the voice part: unenrol from a confirmed voice that is no longer this speaker, then enrol, rename
    /// only, or clear a stale automatic match.
    private static func sealedSave(_ state: NamingState) -> [NamingEffect] {
        let input = state.input
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var effects: [NamingEffect] = []
        if name != input.namedLabel { effects.append(.relabel(speakerID: input.speakerID, name: name)) }
        let previous = confirmedID(input)
        let target = target(state, previous: previous, name: name)
        if let previous, previous != target { effects.append(.unenrol(speakerID: input.speakerID)) }
        if let effect = rememberEffect(state, previous: previous, target: target, name: name) { effects.append(effect) }
        return effects
    }

    private static func rememberEffect(_ state: NamingState, previous: UUID?, target: UUID?, name: String) -> NamingEffect? {
        let input = state.input
        var auto: UUID?
        if case .auto(let voice, _) = input.match { auto = voice }
        let autoName = auto.flatMap { id in input.voices.first { $0.id == id }?.name }
        let staleAuto = auto != nil && auto != target && (autoName.map { !NameMatch.same($0, name) } ?? true)
        if effectiveRemember(state), let previous, previous == target {
            guard state.renameAnswer == true, let saved = input.voices.first(where: { $0.id == previous }), saved.name != name
            else { return nil }
            return .renameVoice(previous, name: name)
        }
        if effectiveRemember(state) { return .rememberVoice(speakerID: input.speakerID, voiceID: target, name: name) }
        if staleAuto { return .clearMatch(speakerID: input.speakerID) }
        return nil
    }

    /// The voice the speaker is saved as: the bound one, else the confirmed one if the rename was answered yes or
    /// the name still is its name.
    private static func target(_ state: NamingState, previous: UUID?, name: String) -> UUID? {
        if let bound = state.boundVoiceID { return bound }
        guard let previous else { return nil }
        let saved = state.input.voices.first { $0.id == previous }
        return state.renameAnswer == true || saved.map { NameMatch.same($0.name, name) } == true ? previous : nil
    }

    // MARK: - Helpers

    private static func canMerge(_ state: NamingState) -> Bool { !state.input.mergeTargets.isEmpty }

    private static func rememberable(_ state: NamingState) -> Bool {
        rememberReason(state.input) == nil && !state.input.voicesReadOnly
    }

    private static func effectiveRemember(_ state: NamingState) -> Bool { state.remember && rememberable(state) }

    private static func confirmedID(_ input: NamingInput) -> UUID? {
        if case .confirmed(let voice, _) = input.match { return voice }
        return nil
    }

    private static func confirmedVoice(_ input: NamingInput) -> SavedVoice? {
        confirmedID(input).flatMap { id in input.voices.first { $0.id == id } }
    }

    private static func linkedVoice(_ input: NamingInput) -> SavedVoice? {
        input.match.linkedVoiceID.flatMap { id in input.voices.first { $0.id == id } }
    }

    private static func rankedVoices(_ input: NamingInput) -> [NameMatch.Ranked] {
        NameMatch.rank(input.print, voices: input.voices, model: input.currentModel, suggest: VoiceThresholds.ios.suggest)
    }
}

private extension VoiceMatchState {
    var linkedVoiceID: UUID? {
        switch self {
        case .auto(let voice, _), .confirmed(let voice, _): voice
        default: nil
        }
    }
}
