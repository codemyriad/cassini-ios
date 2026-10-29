import Foundation

/// The pure reducer of the Name a speaker sheet: events in, sheet state and effects out. The app keeps one
/// `NamingState` while the sheet is open, shows `ui` and `mergeUI`, and carries out the effects (`NamingCommit`).
///
/// The save follows Android's `rememberVoice`: a confirmed voice that is no longer this speaker is unenrolled, a
/// stale automatic match is cleared, then the print is enrolled into the bound or a new voice. A draft (a running job,
/// `NamingInput.draft`) saves and merges into the draft's names instead (`draftName`, `mergeDraft`).
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
        let remember = rememberReason(input) == nil
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
                                         restorePlaceholder: input.namedLabel.map { NameMatch.same($0, voice.name) } ?? false,
                                         draft: input.draft)
        return NamingResult(nil, [reject, .close])
    }

    private static func playSample(_ state: NamingState) -> [NamingEffect] {
        guard state.input.canSample, let sample = state.input.sample else { return [] }
        return [.playRange(sample)]
    }

    private static func confirmMerge(_ state: NamingState) -> NamingResult {
        guard let id = state.merge?.target, let target = state.input.mergeTargets.first(where: { $0.speakerID == id })
        else { return NamingResult(state) }
        let source = state.input.speakerID
        guard state.input.draft else { return NamingResult(nil, [.merge(source: source, target: target.speakerID), .close]) }
        let label = DefaultLabels.isDefault(id: target.speakerID, label: target.name) ? nil : target.name
        return NamingResult(nil, [.mergeDraft(source: source, target: target.speakerID, targetLabel: label), .close])
    }

    private static func save(_ state: NamingState) -> NamingResult {
        switch saveState(state) {
        case .disabled: return NamingResult(state)
        case .blockedByQuestion: return NamingResult(state, [.focusQuestion])
        case .enabled: return NamingResult(nil, (state.input.draft ? draftSave(state) : sealedSave(state)) + [.close])
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

    /// Android's draft save (`DraftNames.rename` / `remember`, or `confirm` for a bound voice), then the saved voice's
    /// rename when the rename-saved question was answered yes.
    private static func draftSave(_ state: NamingState) -> [NamingEffect] {
        let input = state.input
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = confirmedID(input)
        let target = target(state, previous: previous, name: name)
        let remember = effectiveRemember(state)
        let voice: DraftVoice? = remember ? target.map(DraftVoice.saved) ?? .new : nil
        let scores = NameMatch.scores(input.print, voices: input.voices)
        let score = target.flatMap { id in scores[id] ?? (input.match.voiceID == id ? input.match.score : nil) } ?? 1
        var effects: [NamingEffect] = [.draftName(speakerID: input.speakerID, name: name, voice: voice,
                                                  confirm: remember && target != nil, score: score)]
        if state.renameAnswer == true, let previous, let saved = input.voices.first(where: { $0.id == previous }),
           saved.name != name {
            effects.append(.renameVoice(previous, name: name))
        }
        return effects
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

    static func canMerge(_ state: NamingState) -> Bool { !state.input.mergeTargets.isEmpty }

    static func rememberable(_ state: NamingState) -> Bool { rememberReason(state.input) == nil }

    static func effectiveRemember(_ state: NamingState) -> Bool { state.remember && rememberable(state) }

    static func confirmedID(_ input: NamingInput) -> UUID? {
        if case .confirmed(let voice, _) = input.match { return voice }
        return nil
    }

    static func confirmedVoice(_ input: NamingInput) -> SavedVoice? {
        confirmedID(input).flatMap { id in input.voices.first { $0.id == id } }
    }

    static func linkedVoice(_ input: NamingInput) -> SavedVoice? {
        input.match.linkedVoiceID.flatMap { id in input.voices.first { $0.id == id } }
    }

    static func rankedVoices(_ input: NamingInput) -> [NameMatch.Ranked] {
        NameMatch.rank(input.print, voices: input.voices, model: input.currentModel, suggest: VoiceThresholds.campplus.suggest)
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
