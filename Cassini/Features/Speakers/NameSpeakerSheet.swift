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
    @FocusState private var nameFocused: Bool
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
                if let state {
                    let ui = SpeakerNaming.ui(state)
                    sheetContent(ui)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            footer(ui)
                        }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(SpeakersCopy.dialogLabel)
            .accessibilityIdentifier("nameSpeakerSheet")
            .navigationDestination(isPresented: mergeShown) {
                if let state, let merge = SpeakerNaming.mergeUI(state) {
                    MergeSheet(merge: merge, sourceOrdinal: state.input.ordinal, tint: { state.input.speakerTint(for: $0) ?? .stone }, send: send)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .tint(.accent)
        .task { await model.open(draft: draft, sheet: handle) }
        .onDisappear { playback.stopSample() }
        .alert(SpeakersCopy.couldNotSave, isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button(SpeakersCopy.ok) { model.failure = nil }
        } message: { Text(model.failure?.message ?? "") }
    }

    /// This speaker's label as stored (D47), or "Speaker N" in the app's language when it has none
    /// (`NoteCopy.speakerLabel`).
    private func shown(_ label: String) -> String {
        NoteCopy.speakerLabel(label, id: speakerID, ordinal: state?.input.ordinal ?? 0)
    }

    /// A sample of this note is playing; it ends by itself at its end, on a pause, an interruption or a lost output.
    private var sampling: Bool { playback.owns(noteID) && playback.state.sample != nil }

    private var mergeShown: Binding<Bool> {
        Binding(get: { state?.merge != nil }, set: { if !$0, state?.merge != nil { send(.closeMerge) } })
    }

    private func sheetContent(_ ui: NameSheetUI) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(ui)
                if !ui.quote.isEmpty {
                    quoteBlock(ui.quote)
                }
                nameSection(ui)
                question(ui)
                if !ui.voices.isEmpty {
                    voiceRows(ui)
                }
                if let name = ui.notName {
                    Button { send(.notThisPerson) } label: {
                        Text(SpeakersCopy.notName(name))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentInk)
                            .frame(minHeight: HitTarget.minimum, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notThisPerson")
                }
                rememberCard(ui)
            }
            .readableWidth()
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .disabled(saving)
    }

    private func header(_ ui: NameSheetUI) -> some View {
        let canPlay = ui.canSample && playback.owns(noteID)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shown(ui.label))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(SpeakersCopy.speaksFor(ui.speakingTime))
                    .font(.footnote)
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { send(.playSample) } label: {
                Image(systemName: sampling ? "stop.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                    .background(Circle().fill(Color.card))
                    .overlay(Circle().strokeBorder(Color.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .opacity(canPlay ? 1 : 0.4)
            .disabled(!canPlay)
            .accessibilityLabel(sampling ? SpeakersCopy.stopSample : SpeakersCopy.playSample)
        }
    }

    private func quoteBlock(_ quote: String) -> some View {
        Text(SpeakersCopy.quoted(quote))
            .font(.subheadline)
            .foregroundStyle(Color.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 15)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.line)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier("speakerQuote")
    }

    private func nameSection(_ ui: NameSheetUI) -> some View {
        let fieldShape = RoundedRectangle(cornerRadius: Radius.field)
        return VStack(alignment: .leading, spacing: 6) {
            Text(SpeakersCopy.nameField)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                TextField(SpeakersCopy.nameField, text: $nameField.handingEdits { text in
                    nameTyped(text)
                    // A name cut to its limit goes back once the field's own edit is done, as in the Rename sheet.
                    if let name = state?.name, name != text {
                        DispatchQueue.main.async { if nameField == text { nameField = name } }
                    }
                }, prompt: Text(verbatim: ""))
                    .font(.body)
                    .foregroundStyle(Color.ink)
                    .focused($nameFocused)
                    .onAppear { nameField = ui.name }
                    .onChange(of: nameField) { _, text in
                        nameTyped(text)
                        if let name = state?.name, name != text { nameField = name }
                    }
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { send(.save) }
                    .accessibilityLabel(SpeakersCopy.nameField)
                    .accessibilityIdentifier("speakerNameField")
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(fieldShape.fill(Color.card))
            .overlay(fieldShape.strokeBorder(nameFocused ? Color.accent : Color.line, lineWidth: nameFocused ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { nameFocused = true }
        }
    }

    /// The same-person or rename-saved notice, focused and pulsed when Save is pressed before it is answered.
    @ViewBuilder private func question(_ ui: NameSheetUI) -> some View {
        if let saved = ui.samePerson {
            questionCard(SpeakersCopy.duplicateNotice(saved),
                         yes: (SpeakersCopy.samePerson, .samePerson), no: (SpeakersCopy.someoneElse, .someoneElse))
        } else if let saved = ui.renameSaved {
            questionCard(SpeakersCopy.renameSavedNotice(saved),
                         yes: (SpeakersCopy.renameSaved, .renameSaved), no: (SpeakersCopy.someoneElse, .keepSaved))
        }
    }

    private func questionCard(_ notice: AttributedString, yes: (String, NamingEvent),
                              no: (String, NamingEvent)) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: Radius.field)
        return VStack(alignment: .leading, spacing: 10) {
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($questionFocused)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { questionButtons(yes: yes, no: no) }
                VStack(alignment: .leading, spacing: 4) { questionButtons(yes: yes, no: no) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(cardShape.fill(Color.sunken))
        .overlay {
            if pulse { cardShape.strokeBorder(Color.speaker0, lineWidth: 2) }
        }
    }

    @ViewBuilder private func questionButtons(yes: (String, NamingEvent), no: (String, NamingEvent)) -> some View {
        Button(yes.0) { send(yes.1) }
            .buttonStyle(SheetPillButtonStyle(primary: true, compact: true))
            .accessibilityIdentifier("questionYes")
        Button(no.0) { send(no.1) }
            .buttonStyle(SheetPillButtonStyle(primary: false, compact: true))
            .accessibilityIdentifier("questionNo")
    }

    private func voiceRows(_ ui: NameSheetUI) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: Radius.field)
        return VStack(alignment: .leading, spacing: 8) {
            Text(ui.ranked ? SpeakersCopy.voicesRanked : SpeakersCopy.voices)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(ui.voices.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(Color.lineSoft).frame(height: 1).accessibilityHidden(true)
                    }
                    Button { send(.pickVoice(row.id)) } label: {
                        HStack(spacing: 10) {
                            SpeakerAvatar(name: row.name, tint: row.tint, size: 32, showsPlaceholderNumber: false)
                            Text(row.name)
                                .font(.body)
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if row.likely {
                                Text(SpeakersCopy.likely)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Color.ink.opacity(0.1), in: Capsule())
                                    .fixedSize()
                            }
                            if state?.boundVoiceID == row.id {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentInk)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state?.boundVoiceID == row.id ? .isSelected : [])
                }
                if ui.showAll {
                    Rectangle().fill(Color.lineSoft).frame(height: 1).accessibilityHidden(true)
                    Button { send(.showAll) } label: {
                        Text(SpeakersCopy.showAll)
                            .font(.body)
                            .foregroundStyle(Color.accentInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(cardShape.fill(Color.card))
            .clipShape(cardShape)
            .overlay(cardShape.strokeBorder(Color.lineSoft, lineWidth: 1))
        }
    }

    private func rememberCard(_ ui: NameSheetUI) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: Radius.field)
        let subtitle = ui.rememberReason.map(SpeakersCopy.rememberReason)
            ?? SpeakersCopy.rememberBody(ui.name.trimmingCharacters(in: .whitespaces),
                                         automatic: settings.automaticallyNameVoices,
                                         pad: UIDevice.current.userInterfaceIdiom == .pad)
        return Toggle(isOn: Binding(get: { ui.remember }, set: { send(.rememberToggled($0)) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SpeakersCopy.remember)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(.accent)
        .disabled(!ui.rememberEnabled)
        .accessibilityIdentifier("rememberVoice")
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(cardShape.fill(Color.card))
        .overlay(cardShape.strokeBorder(Color.lineSoft, lineWidth: 1))
    }

    private func footer(_ ui: NameSheetUI) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.lineSoft).frame(height: 1).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    if ui.canMerge { mergeButton }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        cancelButton
                        saveButton(ui)
                    }
                }
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        cancelButton
                        saveButton(ui)
                    }
                    if ui.canMerge {
                        HStack {
                            mergeButton
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .readableWidth()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color.paper)
        .disabled(saving)
    }

    private var mergeButton: some View {
        Button { send(.mergeInto) } label: {
            Text(SpeakersCopy.mergeInto)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
                .padding(.vertical, 8)
                .frame(minHeight: HitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mergeInto")
    }

    private var cancelButton: some View {
        Button(SpeakersCopy.cancel) { send(.cancel) }
            .buttonStyle(SheetPillButtonStyle(primary: false, compact: false))
    }

    private func saveButton(_ ui: NameSheetUI) -> some View {
        let disabled = saving || ui.save == .disabled
        return Button(SpeakersCopy.saveName) { send(.save) }
            .buttonStyle(SheetPillButtonStyle(primary: true, compact: false))
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
            .accessibilityIdentifier("saveSpeakerName")
    }

    // MARK: - Events

    /// Sends `event`; a name the model chose (a picked voice) goes into the field. The field's own typing is not
    /// written back here (only a name cut to its limit is, above): a name the view rendered one keystroke earlier would
    /// overwrite text typed since.
    private func send(_ event: NamingEvent) {
        model.send(event, sheet: handle)
        if case .nameChanged = event { return }
        if let name = state?.name, name != nameField { nameField = name }
    }

    /// The model takes the name being typed, and the Note screen keeps it. Below iOS 26 this also runs from the field's
    /// binding (`handingEdits`): SwiftUI can skip the `onChange` of a fast typist's last keystroke there, and Save
    /// would store the name without it (iOS 18.2: "Anna Ricci" shown, "Anna Ric" saved). The same text taken twice
    /// changes nothing.
    private func nameTyped(_ text: String) {
        send(.nameChanged(text))
        nameChanged(state?.name ?? text)
    }

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

private struct SheetPillButtonStyle: ButtonStyle {
    let primary: Bool
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primary ? Color.onAccent : Color.ink)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 7 : 10)
            .background {
                Capsule().fill(primary ? Color.accentStrong : Color.ink.opacity(0.1))
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .frame(minHeight: HitTarget.minimum)
            .contentShape(Rectangle())
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
