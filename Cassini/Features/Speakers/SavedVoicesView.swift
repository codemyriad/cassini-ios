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
    @State private var renameText = ""
    @State private var forgettingAllData = false

    private var people: [SavedVoiceSummary] { voices.summaries }
    private var readOnly: Bool { voices.isReadOnly }
    private var dialog: SavedVoicesDialog? { SavedVoicesScreen(dialog: dialogKey).dialog(people: people, readOnly: readOnly) }

    var body: some View {
        List {
            Section {
                Label(SpeakersCopy.privacy, systemImage: "lock").font(.footnote).foregroundStyle(Color.muted)
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
                    ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                        PersonRow(person: person, index: index, editable: !readOnly, send: send)
                    }
                } footer: {
                    if !readOnly { Text(SpeakersCopy.footnote) }
                }
            }
            if people.isEmpty, !readOnly {
                Section { Text(SpeakersCopy.footnote).font(.footnote).foregroundStyle(Color.muted) }
            }
            if !people.isEmpty {
                Section {
                    Button(SpeakersCopy.forgetEveryoneMore, role: .destructive) { send(.forgetEveryone) }
                        .disabled(readOnly)
                        .accessibilityIdentifier("forgetEveryone")
                }
            } else if voices.offersForgetAllData {
                Section {
                    Button(SpeakersCopy.forgetAllData, role: .destructive) { forgettingAllData = true }
                } footer: { Text(SpeakersCopy.forgetAllDataBody) }
            }
        }
        .navigationTitle(SpeakersCopy.voices)
        .task { await voices.refresh() }
        .alert(SpeakersCopy.renameSaved, isPresented: presented(where: { if case .rename = $0 { true } else { false } })) {
            TextField(SpeakersCopy.nameField, text: $renameText)
                .textInputAutocapitalization(.words)
                .onChange(of: renameText) { _, text in if text.count > Limits.nameMaxLength { renameText = String(text.prefix(Limits.nameMaxLength)) } }
            Button(SpeakersCopy.cancel, role: .cancel) { send(.dismissDialog) }
            Button(SpeakersCopy.renameSaved) {
                if case .rename(let id, _) = dialog { send(.renameConfirmed(id, name: renameText)) }
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
        .onChange(of: dialogKey, initial: true) {
            if case .rename(_, let name) = dialog { renameText = name }
        }
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
    /// Saved-voice avatars cycle by list position, as on Android.
    private static let tints: [Color] = [.speakerTints[1], .speakerTints[5], .toneWarn, .speakerTints[3]]

    let person: SavedVoiceSummary
    let index: Int
    let editable: Bool
    let send: (SavedVoicesEvent) -> Void

    var body: some View {
        HStack(spacing: 12) {
            SpeakerAvatar(name: person.name, tint: Self.tints[index % Self.tints.count])
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                Text(SpeakersCopy.meta(notes: person.notes, seconds: person.confirmedSeconds)).font(.caption).foregroundStyle(Color.muted)
                if person.stale { Text(SpeakersCopy.stale).font(.caption).foregroundStyle(Color.toneWarn) }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Menu {
                Button(SpeakersCopy.renameMore) { send(.rename(person.id)) }
                Button(SpeakersCopy.forgetMore, role: .destructive) { send(.forget(person.id)) }
            } label: {
                Image(systemName: "ellipsis").frame(width: HitTarget.minimum, height: HitTarget.minimum)
            }
            .disabled(!editable)
            .accessibilityLabel(SpeakersCopy.options(person.name))
        }
        .padding(.vertical, 2)
    }
}
