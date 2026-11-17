import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Saved voices: the privacy line, the "can't be read" banner while the list is read-only, the people (by notes, then
/// confirmed speech, then name) with their options, the footnote, and Forget everyone. The open dialog is kept with
/// the scene (`SavedVoicesScreen`).
struct SavedVoicesView: View {
    @Environment(VoicesStore.self) private var voices
    @Environment(ErrorPresenter.self) private var errors
    @SceneStorage("savedVoices.dialog") private var dialogKey: String?
    @State private var enrolling = false
    @Environment(Router.self) private var router
    @State private var forgettingAllData = false

    private var people: [SavedVoiceSummary] { voices.summaries }
    private var readOnly: Bool { voices.isReadOnly }
    private var dialog: SavedVoicesDialog? { SavedVoicesScreen(dialog: dialogKey).dialog(people: people, readOnly: readOnly) }

    var body: some View {
        List {
            Section {
                Button(Wave6Copy.voicesEnrollAddAction) {
                    Task {
                        if await voices.printsReady() { enrolling = true }
                        else { router.push(.modelDownload(noteID: nil, part: .speakers)) }
                    }
                }
                .disabled(readOnly)
            }
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text(SettingsPhase2Copy.savedVoicesPrivacy).fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote).foregroundStyle(Color.muted)
            }
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
            if people.isEmpty {
                // A list that can't be read is not known to be empty.
                if !readOnly { Section { Text(SpeakersCopy.empty).foregroundStyle(Color.muted) } }
            } else {
                Section {
                    ForEach(people) { person in
                        PersonRow(person: person, editable: !readOnly, send: send)
                    }
                }
            }
            if !people.isEmpty {
                Section {
                    Button(SettingsPhase2Copy.forgetEveryone, role: .destructive) { send(.forgetEveryone) }
                        .foregroundStyle(Color.toneError)
                        .disabled(readOnly)
                        .accessibilityIdentifier("forgetEveryone")
                }
            } else if voices.offersForgetAllData {
                Section {
                    Button(SpeakersCopy.forgetAllData, role: .destructive) { forgettingAllData = true }
                        .foregroundStyle(Color.toneError)
                } footer: { Text(SpeakersCopy.forgetAllDataBody).foregroundStyle(Color.muted) }
            }
            if !readOnly {
                Section { Text(SettingsPhase2Copy.voicesHowToAdd).font(.footnote).foregroundStyle(Color.muted) }
            }
        }
        .accessibilityIdentifier("savedVoicesList")
        .paperListBackground()
        .readableListWidth()
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
        case .forgetEveryone(let count)?: SpeakersCopy.forgetEveryoneBody(count)
        default: SpeakersCopy.forgetBody
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

/// A person: avatar, name, "14 notes · 22 min confirmed speech", the stale hint, and the options menu.
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
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            SpeakerAvatar(name: person.name, tint: SpeakerTint.named(person.colourIndex), showsPlaceholderNumber: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpeakersCopy.meta(notes: person.notes, seconds: person.confirmedSeconds))
                    .font(.caption).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if person.stale {
                    Text(Wave6Copy.savedVoicesRowStale).font(.caption).foregroundStyle(Color.toneWarn)
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
