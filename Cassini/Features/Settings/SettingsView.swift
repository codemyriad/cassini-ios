import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Settings: App language, Transcription, the banners (notifications off, saved voices unreadable), On-device models, Speakers, Privacy, Your
/// library and About, in that order.
struct SettingsView: View {
    @Environment(ProcessingStore.self) private var processing
    @Environment(SettingsStore.self) private var settings
    #if DEBUG
    @Environment(\.modelInstallRecorder) private var installRecorder
    #endif
    @Environment(SettingsAdapter.self) private var ports
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SettingsModel?
    @State private var loaded = false
    @State private var pendingLoads = 0

    var body: some View {
        Group {
            if let model { SettingsForm(model: model) } else { Color.paper }
        }
        .paperListBackground()
        .overlay(alignment: .topLeading) {
            if loaded { UITestStateMarker(identifier: "settingsLoaded") }
            #if DEBUG
            if let recorder = installRecorder {
                let installing = processing.models.isInstalling
                let download = processing.models.download
                let snapshot = recorder.snapshot
                if !snapshot.requested.isEmpty {
                    UITestStateMarker(identifier: "modelInstallRequested",
                                      value: snapshot.requested.map(\.rawValue).joined(separator: ","))
                    if !installing, download == nil, !snapshot.completed.isEmpty {
                        let consent: [ModelPart] = (settings.downloadsAllowed ? [.speech] : [])
                            + (settings.speakerDownloadsAllowed ? [.speakers] : [])
                        UITestStateMarker(identifier: "modelInstallCompleted", value:
                            "requested=\(snapshot.requested.map(\.rawValue).joined(separator: ","));"
                            + "completed=\(snapshot.completed.map(\.rawValue).joined(separator: ","));"
                            + "consented=\(consent.map(\.rawValue).joined(separator: ","))")
                    }
                }
            }
            #endif
        }
        .navigationTitle(Text("Settings", tableName: "Settings")).navigationBarTitleDisplayMode(.inline)
        .task {
            loaded = false
            pendingLoads += 1
            let model = self.model ?? SettingsModel(ports: ports)
            model.onEffect = { [router] effect in
                switch effect {
                case .open(let route): router.push(route)
                case .openNotificationSettings: NoticesStore.openNotificationSettings()
                case .openAppLanguageSettings: openSystemSettings()
                }
            }
            self.model = model
            await model.appeared()
            pendingLoads -= 1
            loaded = pendingLoads == 0
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let model {
                loaded = false
                pendingLoads += 1
                Task {
                    await model.resumed()
                    pendingLoads -= 1
                    loaded = pendingLoads == 0
                }
            }
        }
    }
}

private struct SettingsForm: View {
    let model: SettingsModel
    @Environment(SettingsStore.self) private var settings
    @Environment(NoticesStore.self) private var notices
    @Environment(SettingsAdapter.self) private var ports

    var body: some View {
        @Bindable var settings = settings
        Form {
            AppLanguageSection(open: model.openAppLanguage, speechLanguageApart: model.showsSpeechLanguage)
            TranscriptionSection(model: model, language: $settings.speechLanguage, autoTranscribe: $settings.autoTranscribe)
            let banners = notices.settingsBanners
            if !banners.isEmpty {
                Section {
                    BannerList(specs: banners, onAction: { spec, action in notices.perform(action, on: spec) },
                               onDismiss: notices.dismiss)
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.compatibilityClear)
            }
            if let speechModels = ports.speechModels {
                if speechModels.shows(.settings) || speechModels.promotionVisible {
                    Section { ParakeetSuggestionView(store: speechModels, placement: .settings) }
                }
            }
            Section {
                if let speechModels = ports.speechModels { SpeechModelChoiceRow(store: speechModels) }
                ForEach(model.models) { row in
                    ModelRowView(row: row, modelName: row.part == .speech && ports.speechModels != nil
                        ? (ports.speechModels?.parakeetCapable == true ? "Parakeet Ultra" : (ports.speechModels?.policy.whistleAvailable == true ? "Whistle" : nil)) : nil) {
                        if row.part == .speech, ports.speechModels?.installation == .unavailable { ports.speechModels?.refresh() }
                        else { model.openModel(row.part) }
                    }
                }
            } header: {
                Text("On-device models", tableName: "Settings").foregroundStyle(Color.muted)
            } footer: {
                Text("Transcription runs on this device. Audio never leaves it.", tableName: "Settings").foregroundStyle(Color.muted)
            }
            Section {
                Toggle(isOn: $settings.identifySpeakers) { Text("Identify speakers after transcription", tableName: "Settings") }
                Toggle(isOn: $settings.automaticallyNameVoices) { Text("Name strong voice matches automatically", tableName: "Settings") }
            } header: {
                Text("Speakers", tableName: "Settings").foregroundStyle(Color.muted)
            } footer: {
                Text("Matches can be wrong; check the names. Only voices you save are used to recognise people.", tableName: "Settings").foregroundStyle(Color.muted)
            }
            PrivacySection(model: model)
            LibrarySection(totals: model.library)
            Section {
                AboutCard(version: model.version, openNotices: model.openLicenses)
            } header: {
                Text("About", tableName: "Settings").foregroundStyle(Color.muted)
            }
        }
        .readableListWidth()
    }
}

/// iOS sets the app's language in the Settings app; the row shows it and opens Cassini's page there.
struct AppLanguageSection: View {
    let open: () -> Void
    /// Transcription has a Speech language picker (Apple Speech devices): the footer points to it.
    let speechLanguageApart: Bool

    private var current: String { Self.name(of: Bundle.main.preferredLocalizations.first ?? "en") }

    /// A language in its own words, with the region where the app has two variants: "Français", "Português (Brasil)",
    /// "Português (Portugal)".
    nonisolated static func name(of code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }

    var body: some View {
        Section {
            Button(action: open) {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(current)
                        Image(systemName: "arrow.up.forward.app").imageScale(.small)
                    }
                } label: {
                    Text("App language", tableName: "Settings").foregroundStyle(Color.ink)
                }
            }
            .accessibilityHint(Text("Opens Cassini in the Settings app", tableName: "Settings"))
            .accessibilityIdentifier("appLanguageRow")
        } header: {
            Text("App language", tableName: "Settings").foregroundStyle(Color.muted)
        } footer: {
            if speechLanguageApart {
                Text("The language of speech is chosen separately, under Transcription.", tableName: "Settings").foregroundStyle(Color.muted)
            }
        }
    }
}

private struct TranscriptionSection: View {
    let model: SettingsModel
    @Binding var language: String
    @Binding var autoTranscribe: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            // Only Apple Speech takes a language; Parakeet hears it, so its devices have no picker.
            if model.showsSpeechLanguage { picker }
            Toggle(isOn: $autoTranscribe) { Text("Transcribe after recording or import", tableName: "Settings") }
        } header: {
            Text("Transcription", tableName: "Settings").foregroundStyle(Color.muted)
        } footer: {
            if model.showsSpeechLanguage {
                Text("A new language applies to the next transcription.", tableName: "Settings").foregroundStyle(Color.muted)
            }
        }
    }

    private var picker: some View {
        Picker(selection: $language) {
            ForEach(model.languageOptions(chosen: language, name: name(of:)), id: \.id) { option in
                Group {
                    if option.installed {
                        Text("\(name(of: option.id)) · Installed", tableName: "Settings")
                    } else {
                        Text(name(of: option.id))
                    }
                }.tag(option.id)
            }
        } label: {
            Text("Speech language", tableName: "Settings")
        }
        // A list of its own rather than a menu: a long language name wraps instead of being cut at large text sizes.
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier("speechLanguagePicker")
    }

    private func name(of identifier: String) -> String { locale.localizedString(forIdentifier: identifier) ?? identifier }
}

/// "Saved voices" and "Recently Deleted", with their counts.
private struct PrivacySection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            Button(action: model.openVoices) {
                SettingsRowLabel(title: String(localized: "Saved voices", table: "Settings"),
                                 subtitle: model.voices == 0
                                    ? String(localized: "None yet", table: "Settings")
                                    : String(localized: "\(model.voices) people", table: "Settings"))
            }
            .accessibilityIdentifier("savedVoicesRow")
            Button(action: model.openTrash) {
                SettingsRowLabel(title: String(localized: "Recently Deleted", table: "Settings"),
                                 subtitle: model.trash == 0
                                    ? String(localized: "Empty", table: "Settings")
                                    : String(localized: "\(model.trash) notes", table: "Settings"))
            }
            .accessibilityIdentifier("recentlyDeletedRow")
        } header: {
            Text("Privacy", tableName: "Settings").foregroundStyle(Color.muted)
        }
    }
}

/// The notes outside Recently Deleted and their audio.
private struct LibrarySection: View {
    let totals: SettingsModel.LibraryTotals

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: "\(totals.notes)")
            } label: {
                Text("Recordings", tableName: "Settings")
            }
            LabeledContent {
                Text(verbatim: TimeText.clock(totals.duration))
            } label: {
                Text("Audio duration", tableName: "Settings")
            }
        } header: {
            Text("Your library", tableName: "Settings").foregroundStyle(Color.muted)
        } footer: {
            Text("Notes in Recently Deleted are not counted. They are deleted for good after 30 days.", tableName: "Settings").foregroundStyle(Color.muted)
        }
    }
}

/// A row that opens a screen: its title, a subtitle and a chevron.
struct SettingsRowLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.ink)
                Text(subtitle).font(.subheadline).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// "Cassini talk 0.1.0 — turns speech into searchable, timed text on your device." and the notices link.
private struct AboutCard: View {
    let version: String
    let openNotices: () -> Void

    /// The name and version in bold ink, then the tagline.
    private var tagline: AttributedString {
        var name = AttributedString("\(ProductName.full) \(version)")
        name.inlinePresentationIntent = .stronglyEmphasized
        name.foregroundColor = Color.ink
        return name + AttributedString(" ")
            + AttributedString(String(localized: "— turns speech into searchable, timed text on your device.", table: "Settings"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                OrbitMark(size: 36)
                Text(tagline).font(.subheadline).foregroundStyle(Color.muted)
            }
            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                Text(verbatim: copyright).font(.footnote).foregroundStyle(Color.muted)
            }
            HStack(spacing: 4) {
                Text("Free software under GPLv3.", tableName: "Settings").foregroundStyle(Color.muted)
                Button(action: openNotices) { Text("Source code and notices", tableName: "Settings").underline() }
                    .tint(.ember).buttonStyle(.borderless)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 6)
    }
}
