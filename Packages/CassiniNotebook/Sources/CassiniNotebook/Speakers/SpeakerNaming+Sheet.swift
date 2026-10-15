import Foundation

/// What the Name a speaker sheet shows of a `NamingState`: its rows, the Merge step, Save, and the questions it asks.
extension SpeakerNaming {
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
            remember: state.remember && reason == nil, rememberEnabled: reason == nil,
            rememberReason: reason, canMerge: canMerge(state), save: saveState(state), draft: input.draft)
    }

    /// The Merge sheet, or nil while the Name sheet shows.
    public static func mergeUI(_ state: NamingState) -> MergeUI? {
        guard let step = state.merge else { return nil }
        let targets = state.input.mergeTargets
        return MergeUI(sourceID: state.input.speakerID, source: state.input.label, targets: targets,
                       confirm: step.target.flatMap { id in targets.first { $0.speakerID == id } },
                       shownVersion: state.input.versions.shown, addedVersion: state.input.versions.added,
                       draft: state.input.draft)
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
        guard effectiveRemember(state), state.boundVoiceID == nil, state.input.hasPrint,
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

    /// Why Remember is off, or nil when it can be on. A draft speaker's speech is its speaking time, as on Android.
    public static func rememberReason(_ input: NamingInput) -> RememberReason? {
        if input.voicesReadOnly { return .readOnly }
        if !input.voiceModelReady { return .noModel }
        let speech = input.draft ? input.speakingTime : input.print?.speechSeconds ?? 0
        guard input.hasPrint, speech >= minimumRememberSeconds else { return .tooLittleSpeech }
        return nil
    }
}
