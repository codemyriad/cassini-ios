import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Name a speaker: the `SpeakerNaming` reducer on screen. Effects that change the note or the saved voices are carried
/// out by `VoicesStore`; while they are written the sheet stays, and a failure keeps it open with its alert.
struct NameSpeakerSheet: View {
    let noteID: UUID
    let speakerID: String
    @Environment(LibraryStore.self) private var library
    @Environment(VoicesStore.self) private var voices
    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: NamingState?
    @State private var saving = false
    @State private var saveError: String?
    @State private var pulse = false
    @AccessibilityFocusState private var questionFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let state { form(SpeakerNaming.ui(state)) } else { ProgressView() }
            }
            .navigationTitle(state.map { SpeakerNaming.ui($0).label } ?? "")
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
                if let state, let merge = SpeakerNaming.mergeUI(state) { MergeSheet(merge: merge, send: send) }
            }
        }
        .tint(.ember)
        .task { state = await voices.namingInput(noteID: noteID, speakerID: speakerID).map(SpeakerNaming.open) }
        .onDisappear { playback.stopSample() }
        .alert(SpeakersCopy.couldNotSave, isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button(SpeakersCopy.ok) { saveError = nil }
        } message: { Text(saveError ?? "") }
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
                TextField(SpeakersCopy.nameField, text: Binding(get: { ui.name }, set: { send(.nameChanged($0)) }))
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
        .disabled(saving)
    }

    private func header(_ ui: NameSheetUI) -> some View {
        HStack(spacing: 12) {
            SpeakerAvatar(speaker: ui.label, ordinal: state?.input.ordinal ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(ui.label).font(.headline).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
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

    private func send(_ event: NamingEvent) {
        guard let current = state, !saving else { return }
        let result = SpeakerNaming.reduce(current, event)
        var writes: [NamingEffect] = []
        for effect in result.effects {
            switch effect {
            case .playRange(let window): toggleSample(window)
            case .focusQuestion: focusQuestion()
            case .close: break
            default: writes.append(effect)
            }
        }
        guard !writes.isEmpty else {
            if let next = result.state { state = next } else { close() }
            return
        }
        saving = true
        Task {
            do throws(VoicesStore.SaveFailure) {
                try await voices.perform(writes, noteID: noteID, speakerID: speakerID)
                close()
            } catch {
                saveError = error.message
            }
            saving = false
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

/// "Merge Speaker 2 into…": the other speakers with their tint and speaking time; a row asks to confirm.
struct MergeSheet: View {
    let merge: MergeUI
    let send: (NamingEvent) -> Void

    var body: some View {
        List(merge.targets) { target in
            Button { send(.mergeTarget(target.speakerID)) } label: {
                HStack(spacing: 12) {
                    SpeakerAvatar(speaker: target.name, ordinal: target.ordinal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).foregroundStyle(Color.ink)
                        Text(RecordingCopy.compact(target.speakingTime)).font(.caption).foregroundStyle(Color.muted)
                    }
                }.frame(minHeight: HitTarget.minimum)
            }
            .accessibilityIdentifier("mergeTarget-\(target.speakerID)")
        }
        .navigationTitle(SpeakersCopy.mergeTitle(merge.source))
        .navigationBarTitleDisplayMode(.inline)
        .alert(merge.confirm.map { SpeakersCopy.mergeConfirmTitle(merge.source, $0.name) } ?? "",
               isPresented: Binding(get: { merge.confirm != nil }, set: { if !$0 { send(.cancelMerge) } }),
               presenting: merge.confirm) { target in
            Button(SpeakersCopy.cancel, role: .cancel) { send(.cancelMerge) }
            Button(SpeakersCopy.merge) { send(.confirmMerge) }
        } message: { target in
            Text(SpeakersCopy.mergeConfirmBody(merge.source, target.name, added: merge.addedVersion, shown: merge.shownVersion))
        }
    }
}
