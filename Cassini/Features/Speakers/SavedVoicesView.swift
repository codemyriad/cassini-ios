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
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @State private var sampleOwner = PlaybackOwner()
    @State private var samples: [UUID: SavedVoicePlayback] = [:]
    @Environment(Router.self) private var router
    @State private var forgettingAllData = false

    private var people: [SavedVoiceSummary] { voices.summaries }
    private var readOnly: Bool { voices.isReadOnly }
    private var dialog: SavedVoicesDialog? { SavedVoicesScreen(dialog: dialogKey).dialog(people: people, readOnly: readOnly) }

    var body: some View {
        List {
            VoiceSetupSection()
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
                    Text(Wave6Copy.savedVoicesPrivacyPhone).fixedSize(horizontal: false, vertical: true)
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
                        PersonRow(person: person, editable: !readOnly, sample: samples[person.id],
                                  owner: sampleOwner, send: send)
                    }
                } footer: {
                    if !readOnly { Text(SpeakersCopy.footnote).foregroundStyle(Color.muted) }
                }
            }
            if people.isEmpty, !readOnly {
                Section { Text(SpeakersCopy.footnote).font(.footnote).foregroundStyle(Color.muted) }
            }
            if !people.isEmpty {
                Section {
                    Button(SpeakersCopy.forgetEveryoneMore, role: .destructive) { send(.forgetEveryone) }
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
        }
        .paperListBackground()
        .readableListWidth()
        .navigationTitle(SpeakersCopy.voices)
        .task {
            await voices.refresh()
        }
        .task(id: voices.savedVoices) {
            let people = voices.savedVoices, notes = library.notes, root = library.root
            let prepared = await Task.detached { SavedVoicePlayback.samples(voices: people, notes: notes, root: root) }.value
            guard !Task.isCancelled else { return }
            samples = prepared
        }
        .onDisappear { playback.leave(sampleOwner) }
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
    let sample: SavedVoicePlayback?
    let owner: PlaybackOwner
    @Environment(PlaybackStore.self) private var playback
    let send: (SavedVoicesEvent) -> Void

    private var sampleCount: String {
        let count = person.voice.samples.count
        let language = DefaultLabels.appLanguage.replacingOccurrences(of: "_", with: "-")
        let one = count == 1 || (count == 0 && (language.hasPrefix("fr") || language == "pt-BR"))
        return (one ? Wave6Copy.savedVoicesRowSampleCountOne : Wave6Copy.savedVoicesRowSampleCountOther)
            .replacingOccurrences(of: "{n}", with: count.formatted(.number.locale(Locale(identifier: language))))
    }

    var body: some View {
        HStack(spacing: 12) {
            SpeakerAvatar(name: person.name, tint: SpeakerTint.named(person.colourIndex), showsPlaceholderNumber: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                Text(SpeakersCopy.meta(notes: person.notes, seconds: person.confirmedSeconds))
                    .font(.caption).foregroundStyle(Color.muted)
                Text(sampleCount).font(.caption).foregroundStyle(Color.muted)
                if person.stale { Text(Wave6Copy.savedVoicesRowStale).font(.caption).foregroundStyle(Color.toneWarn) }
                else { Text(Wave6Copy.savedVoicesRowStatusReady).font(.caption).foregroundStyle(Color.muted) }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let sample {
                let playing = playback.owns(sample.source.noteID) && playback.state.sample != nil
                Button {
                    if playing { playback.stopSample() }
                    else {
                        playback.controller.show(sample.source, at: 0, owner: owner)
                        _ = playback.controller.playRange(sample.source.noteID, from: sample.start, to: sample.end)
                    }
                } label: { Image(systemName: playing ? "stop.fill" : "play.fill").frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum) }
                .buttonStyle(.borderless)
                .accessibilityLabel((playing ? Wave6Copy.savedVoicesRowStopSample : Wave6Copy.savedVoicesRowPlay)
                    .replacingOccurrences(of: "{name}", with: person.name))
            }
            Menu {
                Button(Wave6Copy.savedVoicesRowRename) { send(.rename(person.id)) }
                Button(Wave6Copy.savedVoicesRowForget, role: .destructive) { send(.forget(person.id)) }
            } label: {
                Image(systemName: "ellipsis").frame(width: HitTarget.minimum, height: HitTarget.minimum)
            }
            .disabled(!editable)
            .accessibilityLabel(SpeakersCopy.options(person.name))
        }
        .padding(.vertical, 2)
    }
}
