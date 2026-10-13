import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Name a speaker: `NameSpeakerModel` (the `SpeakerNaming` reducer and its writes) on screen. The Note screen keeps the
/// name being typed (`nameChanged`) and hands it back as `draft` when the sheet opens again after Cassini was closed.
struct NameSpeakerSheet: View {
    let noteID: UUID
    let speakerID: String
    var draft: String?
    var nameChanged: (String) -> Void = { _ in }
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: NameSpeakerModel
    @State private var pulse = false
    /// The field's own text: a name cut to its limit is put back into the field, which a computed binding cannot do.
    @State private var nameField = ""
    @AccessibilityFocusState private var questionFocused: Bool

    init(model: @autoclosure () -> NameSpeakerModel, draft: String? = nil, nameChanged: @escaping (String) -> Void = { _ in }) {
        let model = model()
        self.noteID = model.noteID
        self.speakerID = model.speakerID
        self.draft = draft
        self.nameChanged = nameChanged
        _model = State(initialValue: model)
    }

    private var state: NamingState? { model.state }
    private var saving: Bool { model.saving }

    var body: some View {
        NavigationStack {
            Group {
                if let state { form(SpeakerNaming.ui(state)) } else { ProgressView() }
            }
            .navigationTitle(state.map { shown(SpeakerNaming.ui($0).label) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(SpeakersCopy.cancel) { send(.cancel) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(SpeakersCopy.saveName) { send(.save) }
                        .disabled(saving || state.map { SpeakerNaming.ui($0).save == .disabled } ?? true)
                        .accessibilityIdentifier("saveSpeakerName")
                }
            }
            .navigationDestination(isPresented: mergeShown) {
                if let state, let merge = SpeakerNaming.mergeUI(state) {
                    MergeSheet(merge: merge, sourceOrdinal: state.input.ordinal, send: send)
                }
            }
        }
        .tint(.ember)
        .task { await model.open(draft: draft, sheet: handle) }
        .onDisappear { playback.stopSample() }
        .alert(SpeakersCopy.couldNotSave, isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button(SpeakersCopy.ok) { model.failure = nil }
        } message: { Text(model.failure?.message ?? "") }
    }

    /// This speaker's label in the reader's language (`NoteCopy.speakerLabel`).
    private func shown(_ label: String) -> String {
        NoteCopy.speakerLabel(label, id: speakerID, ordinal: state?.input.ordinal ?? 0)
    }

    /// A sample of this note is playing; it ends by itself at its end, on a pause, an interruption or a lost output.
    private var sampling: Bool { playback.owns(noteID) && playback.state.sample != nil }

    private var mergeShown: Binding<Bool> {
        Binding(get: { state?.merge != nil }, set: { if !$0, state?.merge != nil { send(.closeMerge) } })
    }

    @ViewBuilder private func form(_ ui: NameSheetUI) -> some View {
        Form {
            Section { header(ui) }
            Section {
                TextField(SpeakersCopy.nameField, text: $nameField)
                    .onAppear { nameField = ui.name }
                    .onChange(of: nameField) { _, text in
                        send(.nameChanged(text))
                        nameChanged(state?.name ?? text)
                        if let name = state?.name, name != text { nameField = name }
                    }
                    .onChange(of: ui.name) { _, name in if name != nameField { nameField = name } }
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { send(.save) }
                    .accessibilityIdentifier("speakerNameField")
            }
            question(ui)
            if !ui.voices.isEmpty { voiceRows(ui) }
            if let name = ui.notName {
                Section { Button(SpeakersCopy.notName(name)) { send(.notThisPerson) }.accessibilityIdentifier("notThisPerson") }
            }
            Section {
                Toggle(SpeakersCopy.remember, isOn: Binding(get: { ui.remember }, set: { send(.rememberToggled($0)) }))
                    .disabled(!ui.rememberEnabled)
                    .accessibilityIdentifier("rememberVoice")
            } footer: {
                Text(ui.rememberReason.map(SpeakersCopy.rememberReason)
                     ?? SpeakersCopy.rememberBody(ui.name.trimmingCharacters(in: .whitespaces), automatic: settings.automaticallyNameVoices))
            }
            if ui.canMerge {
                Section { Button(SpeakersCopy.mergeInto) { send(.mergeInto) }.accessibilityIdentifier("mergeInto") }
            }
        }
        .paperListBackground()
        .disabled(saving)
    }

    private func header(_ ui: NameSheetUI) -> some View {
        HStack(spacing: 12) {
            SpeakerAvatar(speaker: ui.label, ordinal: state?.input.ordinal ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown(ui.label)).font(.headline).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                Text(SpeakersCopy.speaksFor(ui.speakingTime)).font(.caption).foregroundStyle(Color.muted)
            }
            Spacer()
            Button { send(.playSample) } label: {
                Image(systemName: sampling ? "stop.fill" : "play.fill")
                    .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                    .background(Color.ember.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(Color.ember)
            .disabled(!ui.canSample || !playback.owns(noteID))
            .accessibilityLabel(sampling ? SpeakersCopy.stopSample : SpeakersCopy.playSample)
        }
    }

    /// The same-person or rename-saved question, focused and pulsed when Save is pressed before it is answered.
    @ViewBuilder private func question(_ ui: NameSheetUI) -> some View {
        if let saved = ui.samePerson {
            questionCard(SpeakersCopy.alreadySaved(saved), SpeakersCopy.samePersonQuestion,
                         yes: (SpeakersCopy.samePerson, .samePerson), no: (SpeakersCopy.someoneElse, .someoneElse))
        } else if let saved = ui.renameSaved {
            questionCard(SpeakersCopy.savedAs(saved), SpeakersCopy.renameSavedQuestion,
                         yes: (SpeakersCopy.renameSaved, .renameSaved), no: (SpeakersCopy.someoneElse, .keepSaved))
        }
    }

    private func questionCard(_ statement: String, _ question: String, yes: (String, NamingEvent),
                              no: (String, NamingEvent)) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(statement)
                Text(question).fontWeight(.semibold)
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($questionFocused)
            Button(yes.0) { send(yes.1) }.accessibilityIdentifier("questionYes")
            Button(no.0) { send(no.1) }.accessibilityIdentifier("questionNo")
        }
        .listRowBackground(Color.toneWarn.opacity(pulse ? 0.3 : 0.1))
    }

    private func voiceRows(_ ui: NameSheetUI) -> some View {
        Section(ui.ranked ? SpeakersCopy.voicesRanked : SpeakersCopy.voices) {
            ForEach(ui.voices) { row in
                Button { send(.pickVoice(row.id)) } label: {
                    HStack {
                        Text(row.name).foregroundStyle(Color.ink)
                        Spacer()
                        if row.likely {
                            Text(SpeakersCopy.likely).font(.caption.weight(.medium)).foregroundStyle(Color.toneOK)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Tone.ok.background, in: Capsule())
                        }
                        if state?.boundVoiceID == row.id { Image(systemName: "checkmark").foregroundStyle(Color.ember) }
                    }.frame(minHeight: HitTarget.minimum)
                }
                .accessibilityAddTraits(state?.boundVoiceID == row.id ? .isSelected : [])
            }
            if ui.showAll { Button(SpeakersCopy.showAll) { send(.showAll) } }
        }
    }

    // MARK: - Events

    private func send(_ event: NamingEvent) { model.send(event, sheet: handle) }

    private func handle(_ action: NameSpeakerModel.SheetAction) {
        switch action {
        case .toggleSample(let window): toggleSample(window)
        case .focusQuestion: focusQuestion()
        case .close: close()
        }
    }

    private func toggleSample(_ window: SampleWindow) {
        if sampling {
            playback.stopSample()
        } else if let note = library.note(noteID) {
            _ = playback.playSample(note, from: window.start, to: window.start + window.duration)
        }
    }

    private func focusQuestion() {
        questionFocused = true
        AccessibilityNotification.Announcement(SpeakersCopy.answerFirst).post()
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.25)) { pulse = true } completion: {
            withAnimation(.easeInOut(duration: 0.35)) { pulse = false }
        }
    }

    private func close() {
        playback.stopSample()
        dismiss()
    }
}

extension NameSpeakerModel.Failure {
    /// Why the save did not happen, as the sheet's alert says it.
    var message: String {
        switch self {
        case .save(let failure): failure.message
        case .readOnly(let reason): NoteCopy.readOnly(reason)
        }
    }
}
