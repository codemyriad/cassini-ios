import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Saved voices: stale notice, the people list (by notes, then speech, then name) with their options,
/// Forget everyone, and the bottom privacy footnote. The open dialog is kept with the scene (`SavedVoicesScreen`).
struct SavedVoicesView: View {
    @Environment(VoicesStore.self) private var voices
    @Environment(ErrorPresenter.self) private var errors
    @SceneStorage("savedVoices.dialog") private var dialogKey: String?
    @State private var enrolling = false
    @Environment(Router.self) private var router
    @State private var forgettingAllData = false

    private var people: [SavedVoiceSummary] { voices.summaries }
    private var stalePeople: [SavedVoiceSummary] { people.filter(\.stale) }
    private var readOnly: Bool { voices.isReadOnly }
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var dialog: SavedVoicesDialog? { SavedVoicesScreen(dialog: dialogKey).dialog(people: people, readOnly: readOnly) }

    var body: some View {
        Group {
            if people.isEmpty && !readOnly {
                emptyState
            } else {
                populatedList
            }
        }
        .navigationTitle(SpeakersCopy.voices)
        .task {
            await voices.refresh()
        }
        .sheet(isPresented: $enrolling) { VoiceEnrollmentView() }
        .sheet(isPresented: presented(where: { if case .rename = $0 { true } else { false } })) {
            if case .rename(let id, let name)? = dialog {
                // Android's rename dialog: 80 characters, "Enter a name." under the field, Save once it changed.
                RenameSheet(navigationTitle: SpeakersCopy.renameSaved, fieldLabel: SpeakersCopy.nameField, original: name,
                            limit: Limits.nameMaxLength, blankMessage: SpeakersCopy.nameBlank, saveLabel: SpeakersCopy.save,
                            cancelLabel: SpeakersCopy.cancel, fieldIdentifier: "renameVoiceField", capitalization: .words,
                            clean: Self.cleanName) { cleaned in
                    send(.renameConfirmed(id, name: cleaned))
                    return true
                }
            }
        }
        .alert(dialogTitle, isPresented: presented(where: { if case .rename = $0 { false } else { true } })) {
            Button(SpeakersCopy.cancel, role: .cancel) { send(.dismissDialog) }
            Button(dialogAction, role: .destructive) { send(.confirmDialog) }
        } message: { Text(dialogBody) }
        .alert(SpeakersCopy.forgetAllData, isPresented: $forgettingAllData) {
            Button(SpeakersCopy.cancel, role: .cancel) {}
            Button(SpeakersCopy.forgetAllData, role: .destructive) { Task { report(await voices.forgetEveryone()) } }
        } message: { Text(SpeakersCopy.forgetAllDataBody) }
    }

    private var populatedList: some View {
        List {
            if readOnly {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SpeakersCopy.unreadableTitle).font(.subheadline.weight(.semibold))
                        Text(SpeakersCopy.unreadableBody).font(.subheadline)
                    }
                    .foregroundStyle(Color.ink)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("voicesUnreadable")
                }
                .listRowBackground(Tone.error.background)
            }
            if !stalePeople.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SavedVoicesPhase2Copy.staleTitle(stalePeople.count))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.toneWarn)
                        Text(SavedVoicesPhase2Copy.staleBody(staleNamesText))
                            .font(.subheadline)
                            .foregroundStyle(Color.ink)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("voicesStaleNotice")
                }
                .listRowBackground(Tone.warn.background)
            }
            if !people.isEmpty {
                Section {
                    ForEach(people) { person in
                        PersonRow(person: person, editable: !readOnly, send: send)
                    }
                } header: {
                    HStack {
                        Text(SettingsPhase2Copy.peopleCount(people.count))
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Color.muted)
                        Spacer()
                        Button {
                            startEnrollment()
                        } label: {
                            Label(SavedVoicesPhase2Copy.addVoice, systemImage: "plus")
                                .font(.subheadline.weight(.medium))
                                .frame(minHeight: HitTarget.minimum)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .textCase(nil)
                        .foregroundStyle(Color.accentInk)
                        .disabled(readOnly)
                        .accessibilityIdentifier("addSavedVoice")
                    }
                } footer: {
                    Text(SavedVoicesPhase2Copy.caption)
                        .font(.footnote)
                        .foregroundStyle(Color.muted)
                }
                .listRowBackground(Color.card)
                .listRowSeparatorTint(Color.line)
                Section {
                    Button(SettingsPhase2Copy.forgetEveryone, role: .destructive) { send(.forgetEveryone) }
                        .foregroundStyle(Color.toneError)
                        .disabled(readOnly)
                        .accessibilityIdentifier("forgetEveryone")
                }
                .listRowBackground(Color.card)
                .listRowSeparatorTint(Color.line)
            } else if voices.offersForgetAllData {
                Section {
                    Button(SpeakersCopy.forgetAllData, role: .destructive) { forgettingAllData = true }
                        .foregroundStyle(Color.toneError)
                } footer: { Text(SpeakersCopy.forgetAllDataBody).foregroundStyle(Color.muted) }
                .listRowBackground(Color.card)
                .listRowSeparatorTint(Color.line)
            }
            Section {
                privacyFootnote
                    .listRowBackground(Color.canvasClear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 16, trailing: 4))
            }
        }
        .accessibilityIdentifier("savedVoicesList")
        .paperListBackground()
        .readableListWidth()
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    Text(SpeakersCopy.empty)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text(SavedVoicesPhase2Copy.emptyBody)
                        .font(.subheadline)
                        .foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center)
                    Button(Wave6Copy.voicesEnrollAddAction) {
                        startEnrollment()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .tint(Color.accentStrong)
                    .padding(.top, 8)
                    .accessibilityIdentifier("addSavedVoice")
                    if voices.offersForgetAllData {
                        Button(SpeakersCopy.forgetAllData, role: .destructive) { forgettingAllData = true }
                            .font(.subheadline)
                            .foregroundStyle(Color.toneError)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center)
            .accessibilityIdentifier("savedVoicesList")
            privacyFootnote
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper.ignoresSafeArea())
    }

    private var privacyFootnote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(Color.accentInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pad ? SavedVoicesPhase2Copy.footnoteMadeOnIpad : SavedVoicesPhase2Copy.footnoteMadeOnIphone)
                Text(SavedVoicesPhase2Copy.footnoteNamesOnly)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(Color.muted)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("savedVoicesPrivacyFootnote")
    }

    private var staleNamesText: String {
        let names = stalePeople.map(\.name)
        if names.count == 1 { return names[0] }
        return ListFormatter.localizedString(byJoining: names)
    }

    private func startEnrollment() {
        Task {
            if await voices.printsReady() { enrolling = true }
            else { router.push(.modelDownload(noteID: nil, part: .speakers)) }
        }
    }

    /// A saved voice's name as it is stored: trimmed; nil when blank.
    private static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func presented(where matches: @escaping (SavedVoicesDialog) -> Bool) -> Binding<Bool> {
        Binding(get: { dialog.map(matches) ?? false }, set: { if !$0, dialog.map(matches) == true { send(.dismissDialog) } })
    }

    private var dialogTitle: String {
        switch dialog {
        case .forget(_, let name)?: SpeakersCopy.forgetTitle(name)
        case .forgetEveryone?: SpeakersCopy.forgetEveryoneTitle
        default: ""
        }
    }

    private var dialogBody: String {
        switch dialog {
        case .forget(_, let name)?: SpeakersCopy.forgetBody(name)
        case .forgetEveryone(let count)?: SpeakersCopy.forgetEveryoneBody(count)
        default: ""
        }
    }

    private var dialogAction: String {
        if case .forgetEveryone? = dialog { SpeakersCopy.forgetEveryone } else { SpeakersCopy.forget }
    }

    private func send(_ event: SavedVoicesEvent) {
        var screen = SavedVoicesScreen(dialog: dialogKey)
        let action = screen.reduce(event, readOnly: readOnly)
        dialogKey = screen.dialog
        guard let action else { return }
        Task {
            switch action {
            case .rename(let id, let name): report(await voices.rename(id, name: name))
            case .forget(let id): report(await voices.forget(id))
            case .forgetEveryone: report(await voices.forgetEveryone())
            }
        }
    }

    private func report(_ edit: VoiceEdit) {
        if let message = SpeakersCopy.message(edit) { errors.present(message) }
    }
}

/// A person: avatar, name, "31 meetings · 4 h 12 min", the stale pill, and the options menu.
private struct PersonRow: View {
    let person: SavedVoiceSummary
    let editable: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let send: (SavedVoicesEvent) -> Void

    var body: some View {
        // At accessibility sizes the name, counts and status need the row's full width;
        // keeping the avatar and both controls beside them squeezes words into fragments.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            SpeakerAvatar(name: person.name, tint: SpeakerTint.named(person.colourIndex), showsPlaceholderNumber: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpeakersCopy.meta(notes: person.notes, seconds: person.confirmedSeconds))
                    .font(.caption).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if person.stale {
                    Text(SavedVoicesPhase2Copy.rowNeedsNaming)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.toneWarn)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Tone.warn.background, in: Capsule())
                        .padding(.top, 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            controls
        }
        .padding(.vertical, 2)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Button(SettingsPhase2Copy.voiceRename) { send(.rename(person.id)) }
                Button(SettingsPhase2Copy.voiceForget, role: .destructive) { send(.forget(person.id)) }
            } label: {
                Image(systemName: "ellipsis").frame(width: HitTarget.minimum, height: HitTarget.minimum)
            }
            .disabled(!editable)
            .accessibilityLabel(SettingsPhase2Copy.voiceOptions.replacingOccurrences(of: "{name}", with: person.name))
        }
        .fixedSize()
    }
}
