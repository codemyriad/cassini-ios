import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The shared phone Settings map, with choices and model details one layer below it.
struct SettingsView: View {
    var page: SettingsPage? = nil
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

    private var pageTitle: String {
        switch page {
        case .transcription: SettingsPhase2Copy.transcription
        case .speakers: SettingsPhase2Copy.speakers
        case .about: SettingsPhase2Copy.about
        case .backup: SettingsPhase2Copy.backup
        case nil: String(localized: "Settings", table: "Settings")
        }
    }

    var body: some View {
        Group {
            if let model { SettingsForm(model: model, page: page) } else { Color.paper }
        }
        .paperListBackground()
        .overlay(alignment: .topLeading) {
            if loaded { UITestStateMarker(identifier: "settingsLoaded", value: page?.rawValue ?? "map") }
            #if DEBUG
            if let recorder = installRecorder {
                let installing = processing.models.isInstalling
                let download = processing.models.download
                let snapshot = recorder.snapshot
                if !snapshot.requested.isEmpty {
                    UITestStateMarker(identifier: "modelInstallRequested",
                                      value: snapshot.requested.map(\.rawValue).joined(separator: ","))
                    if !installing, download == nil, snapshot.completed.isEmpty {
                        UITestStateMarker(identifier: "modelInstallCancelled", value: "cancelled")
                    }
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
        .navigationTitle(pageTitle).navigationBarTitleDisplayMode(.inline)
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
    @State private var backupExport = ArchiveExportModel()
    let model: SettingsModel
    let page: SettingsPage?
    @Environment(SettingsStore.self) private var settings
    @Environment(SettingsAdapter.self) private var ports
    @Environment(Router.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var privacy: String {
        (pad ? LibraryWave5Copy.firstRunPrivacyIpad : LibraryWave5Copy.firstRunPrivacyIphone)
            + " " + LibraryWave5Copy.firstRunPrivacyBackups
    }

    var body: some View {
        Form {
            switch page {
            case nil: map
            case .transcription: transcription
            case .speakers: speakers
            case .about: about
            case .backup: BackupSection(archiveExport: backupExport)
            }
        }
        .readableListWidth()
        .shareSheet(item: $backupExport.shareItem)
        // Pushing a detail page also disappears this form. Only leaving the Backup route cancels its work.
        .onDisappear { cancelExportIfClosed() }
        .onChange(of: router.path) { _, _ in cancelExportIfClosed() }
    }

    private func cancelExportIfClosed() {
        if !router.path.contains(.settingsPage(.backup)) { backupExport.cancel() }
    }

    private var map: some View {
        Group {
            Section {
                topic(SettingsPhase2Copy.transcription, answer: speechAnswer, icon: "text.bubble", page: .transcription, id: "transcriptionRow")
                topic(SettingsPhase2Copy.speakers, answer: settings.identifySpeakers ? SettingsPhase2Copy.on : SettingsPhase2Copy.off,
                      icon: "person.2", page: .speakers, id: "speakersRow")
                voicesRow
            } header: { Text(SettingsPhase2Copy.transcripts) } footer: {
                Text(privacy).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                topic(SettingsPhase2Copy.backup, answer: settings.cloudBackup ? SettingsPhase2Copy.icloud : SettingsPhase2Copy.off,
                      icon: "icloud", page: .backup, id: "backupRow")
                Button(action: model.openTrash) {
                    SettingsAnswerRow(title: SettingsPhase2Copy.trash, answer: SettingsPhase2Copy.meetingCount(model.trash), icon: "trash")
                }.accessibilityIdentifier("recentlyDeletedRow")
            } header: { Text(SettingsPhase2Copy.meetings) } footer: {
                Text(SettingsPhase2Copy.libraryStats
                    .replacingOccurrences(of: "{meetings}", with: SettingsPhase2Copy.meetingCount(model.library.notes))
                    .replacingOccurrences(of: "{hours}", with: audioDuration))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("libraryStats")
            }
            Section {
                Button(action: model.openAppLanguage) {
                    SettingsAnswerRow(title: SettingsPhase2Copy.language,
                                      answer: AppLanguageSection.name(of: Bundle.main.preferredLocalizations.first ?? "en"), icon: "globe")
                }
                .accessibilityHint(Text("Opens Cassini in the Settings app", tableName: "Settings"))
                .accessibilityIdentifier("appLanguageRow")
            } header: { Text(SettingsPhase2Copy.app) }
            Section {
                Button { router.push(.settingsPage(.about)) } label: {
                    Group {
                        if typeSize.isAccessibilitySize {
                            // Keep the disclosure beside the mark so long translations use the card's full width.
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    OrbitMark(size: 36)
                                    Spacer()
                                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SettingsPhase2Copy.nameVersion.replacingOccurrences(of: "{version}", with: model.version))
                                        .foregroundStyle(Color.ink)
                                    Text(SettingsPhase2Copy.aboutSubtitle).font(.subheadline).foregroundStyle(Color.muted)
                                }.fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            HStack(spacing: 12) {
                                OrbitMark(size: 36)
                                SettingsRowLabel(title: SettingsPhase2Copy.nameVersion.replacingOccurrences(of: "{version}", with: model.version),
                                                 subtitle: SettingsPhase2Copy.aboutSubtitle)
                            }
                        }
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("aboutRow")
            }
            SettingsNoticesSection()
        }
    }

    private var audioDuration: String {
        if Int64(max(0, model.library.duration) * 1000) == 0 { return SettingsPhase2Copy.audioHours(0) }
        return model.library.duration >= 3600
            ? SettingsPhase2Copy.audioHours(Int(model.library.duration / 3600))
            : MarkdownDate.duration(Int64(max(0, model.library.duration) * 1000), locale: locale,
                underMinute: String(localized: "under 1 min", table: "Export"),
                minutes: String(localized: "{m} min", table: "Export"),
                hours: String(localized: "{h} h {mm} min", table: "Export")) ?? ""
    }

    private var speechAnswer: String {
        if let store = ports.speechModels {
            switch store.displayRecognizer {
            case .whistle: return SettingsPhase2Copy.whistle
            case .parakeet: return SettingsPhase2Copy.parakeet
            case .appleSpeech: return ModelPart.speech.settingsLabel
            }
        }
        if ports.recognizer == .parakeet { return SettingsPhase2Copy.parakeet }
        if ports.recognizer == .whistle { return SettingsPhase2Copy.whistle }
        return ModelPart.speech.settingsLabel
    }

    private var transcription: some View {
        @Bindable var settings = settings
        return Group {
            Section {
                if let store = ports.speechModels, store.whistleAvailable {
                    SpeechChoicesView(store: store, rows: model.models)
                } else {
                    ForEach(model.models.filter { $0.part == .speech }) { row in
                        ModelRowView(row: row) { model.openModel(.speech) }
                    }
                }
                if model.showsSpeechLanguage { SpeechLanguagePicker(model: model, language: $settings.speechLanguage) }
            } header: { Text(SettingsPhase2Copy.forNew) } footer: { Text(SettingsPhase2Copy.keepTranscript) }
            Section {
                Toggle(SettingsPhase2Copy.rightAway, isOn: $settings.autoTranscribe).accessibilityIdentifier("autoTranscribeToggle")
            } header: { Text(SettingsPhase2Copy.afterRecording).padding(.top, 24) } footer: { Text(SettingsPhase2Copy.rightAwaySubtitle) }
            Section {
                Button { router.push(.licenseText(.modelSources)) } label: {
                    SettingsAnswerRow(title: SettingsPhase2Copy.whereFrom, answer: "")
                }
            } header: { Text(SettingsPhase2Copy.goingOnline).padding(.top, 24) } footer: { Text(SettingsPhase2Copy.online) }
            if let store = ports.speechModels, store.promotionVisible {
                Section { ParakeetSuggestionView(store: store, placement: .settings) }
            }
            SettingsNoticesSection()
        }
    }

    private var speakers: some View {
        @Bindable var settings = settings
        return Group {
            Section {
                Toggle(isOn: Binding(get: { settings.identifySpeakers }, set: { value in
                    settings.identifySpeakers = value
                    if value { model.openModel(.speakers, fromSwitch: true) }
                })) { description(SettingsPhase2Copy.tellApart, SettingsPhase2Copy.tellApartDescription) }
                    .toggleStyle(TopAlignedSwitchToggleStyle())
                    .accessibilityIdentifier("identifySpeakersToggle")
                Toggle(isOn: Binding(get: { settings.recogniseSavedVoices }, set: { value in
                    settings.recogniseSavedVoices = value
                    if value { model.openModel(.voices, fromSwitch: true) }
                })) { description(SettingsPhase2Copy.recognise, SettingsPhase2Copy.recogniseDescription) }
                    .toggleStyle(TopAlignedSwitchToggleStyle())
                    .accessibilityIdentifier("recogniseSavedVoicesToggle")
            } header: { Text(SettingsPhase2Copy.whoIsSpeaking) } footer: {
                Text(pad ? SettingsPhase2Copy.runsOnIpad : SettingsPhase2Copy.runsOnIphone)
            }
            Section {
                Toggle(isOn: Binding(get: { settings.rememberPeopleIName }, set: settings.setRememberPeopleIName)) {
                    description(SettingsPhase2Copy.rememberDefault, SettingsPhase2Copy.rememberDefaultSubtitle)
                }
                .toggleStyle(TopAlignedSwitchToggleStyle())
                .accessibilityIdentifier("rememberPeopleToggle")
                Toggle(isOn: $settings.automaticallyNameVoices) {
                    description(SettingsPhase2Copy.autoName, SettingsPhase2Copy.autoNameSubtitle)
                }
                .toggleStyle(TopAlignedSwitchToggleStyle())
                .accessibilityIdentifier("autoNameVoicesToggle")
                voicesRow
            } header: { Text(SettingsPhase2Copy.savedVoices) } footer: { Text(Wave6Copy.savedVoicesPrivacyPhone) }
            // Preserve installation status and size in the second layer, including retries and pending consent.
            Section {
                ForEach(model.models.filter { $0.part != .speech }) { row in
                    ModelRowView(row: row) { model.openModel(row.part) }
                }
            }
            SettingsNoticesSection()
        }
    }

    private var about: some View {
        Group {
            Section {
                VStack(spacing: 8) {
                    OrbitMark(size: 64)
                    Text(verbatim: ProductName.full).font(.title2.weight(.semibold))
                    Text(SettingsPhase2Copy.version.replacingOccurrences(of: "{version}", with: model.version)).foregroundStyle(Color.muted)
                    Text(pad ? SettingsPhase2Copy.taglineIpad : SettingsPhase2Copy.taglineIphone)
                        .multilineTextAlignment(.center).padding(.top, 8)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
            }.listRowBackground(Color.canvasClear)
            Section {
                Link(destination: helpURL) {
                    SettingsRowLabel(title: SettingsPhase2Copy.help, subtitle: SettingsPhase2Copy.helpSubtitle)
                }.accessibilityIdentifier("aboutHelp")
                Link(destination: reportProblemURL) {
                    SettingsRowLabel(title: SettingsPhase2Copy.reportProblem, subtitle: SettingsPhase2Copy.reportProblemSubtitle)
                }.accessibilityIdentifier("aboutReportProblem")
                Button { router.push(.licenseText(.privacy)) } label: {
                    SettingsRowLabel(title: SettingsPhase2Copy.privacy, subtitle: pad ? SettingsPhase2Copy.privacyIpad : SettingsPhase2Copy.privacyIphone)
                }.accessibilityIdentifier("aboutPrivacy")
                Button(action: model.openLicenses) {
                    SettingsRowLabel(title: SettingsPhase2Copy.licences, subtitle: SettingsPhase2Copy.licencesSubtitle)
                }.accessibilityIdentifier("aboutLicences")
                Link(destination: sourceCodeURL) {
                    SettingsRowLabel(title: SettingsPhase2Copy.sourceCode, subtitle: sourceCodeURL.absoluteString.replacingOccurrences(of: "https://", with: ""))
                }.accessibilityIdentifier("aboutSourceCode")
            } footer: { Text(SettingsPhase2Copy.licenceLine.replacingOccurrences(of: "{year}",
                with: String(Calendar(identifier: .gregorian).component(.year, from: Date())))) }
        }
    }

    private var voicesRow: some View {
        Button(action: model.openVoices) {
            SettingsAnswerRow(title: SettingsPhase2Copy.savedVoices, answer: SettingsPhase2Copy.peopleCount(model.voices), icon: "person.crop.circle")
        }.accessibilityIdentifier("savedVoicesRow")
    }

    private func topic(_ title: String, answer: String, icon: String, page: SettingsPage, id: String) -> some View {
        Button { router.push(.settingsPage(page)) } label: {
            SettingsAnswerRow(title: title, answer: answer, icon: icon)
        }.accessibilityIdentifier(id)
    }

    private func description(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.muted)
        }
    }
}

struct SettingsAnswerRow: View {
    let title: String
    let answer: String
    var icon: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.body).foregroundStyle(Color.accentInk)
                    .frame(width: 30, height: 30).background(Color.accentTint, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) { Text(title).foregroundStyle(Color.ink); Text(answer).foregroundStyle(Color.muted) }
                Spacer(minLength: 0)
            } else {
                Text(title).foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                Text(answer).foregroundStyle(Color.muted).multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 40).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct SpeechChoicesView: View {
    let store: SpeechModelsStore
    let rows: [ModelRow]
    @Environment(\.locale) private var locale
    @Environment(Router.self) private var router

    var body: some View {
        choice(.whistle, title: SettingsPhase2Copy.whistle, subtitle: SettingsPhase2Copy.whistleDescription)
        if store.parakeetCapable {
            choice(.parakeet, title: SettingsPhase2Copy.parakeet, subtitle: SettingsPhase2Copy.parakeetDescription)
        }
    }

    private func choice(_ recognizer: SpeechRecognizer, title: String, subtitle: String) -> some View {
        let installed = recognizer == .whistle || store.installation == .verified
        let row = rows.first { $0.part == .speech }
        let action: SpeechModelRowAction = recognizer == .whistle ? .choose
            : .parakeet(installation: store.installation, status: row?.status, runnable: store.canChooseParakeet)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                switch action {
                case .choose: store.choose(recognizer)
                case .verify: store.refresh()
                case .download: router.push(.parakeetDownload)
                case .none: break
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: store.displayRecognizer == recognizer ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(store.displayRecognizer == recognizer ? Color.accent : Color.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).foregroundStyle(Color.ink)
                        Text(subtitle).font(.subheadline).foregroundStyle(Color.muted)
                        if recognizer == .parakeet, installed {
                            if let detail = rows.first(where: { $0.part == .speech })?.size.label(locale: locale) {
                                Text(detail).font(.caption).foregroundStyle(Color.muted)
                                    .accessibilityIdentifier("installedParakeetSize")
                            }
                            Text(ModelRowStatus.ready.label).font(.caption).foregroundStyle(Color.muted)
                        }
                    }
                    if recognizer == .whistle {
                        Spacer(minLength: 8)
                        Text(SettingsPhase2Copy.builtIn).font(.subheadline).foregroundStyle(Color.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).disabled(action == .none)
                .accessibilityIdentifier(recognizer == .whistle ? "chooseWhistle" : "chooseParakeet")
                .accessibilityAddTraits(store.displayRecognizer == recognizer ? [.isSelected] : [])
            if recognizer == .parakeet, !installed {
                VStack(spacing: 4) {
                    if action == .download {
                        Button(SettingsPhase2Copy.download) { router.push(.parakeetDownload) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .accessibilityIdentifier("downloadParakeet")
                    }
                    Text(SizeCopy.text(ModelDownloadPlan.fullDownloadBytes(.speech), locale: locale)).font(.caption).foregroundStyle(Color.muted)
                    if let row = rows.first(where: { $0.part == .speech }), row.status != .notDownloaded {
                        Text(row.status.label).font(.caption).foregroundStyle(row.status.tone.color)
                    }
                }
            }
        }.padding(.vertical, 6)
    }
}

/// Aligns a Form switch to the first line of a multi-line label, keeping single-line rows on the default centred style.
struct TopAlignedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// A row that opens a screen: its title, a subtitle and a chevron.
struct SettingsRowLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.ink)
                Text(subtitle).font(.subheadline).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsNoticesSection: View {
    @Environment(NoticesStore.self) private var notices
    var body: some View {
        let banners = notices.settingsBanners
        if !banners.isEmpty {
            Section {
                BannerList(specs: banners, onAction: { spec, action in notices.perform(action, on: spec) },
                           onDismiss: notices.dismiss)
            }
            .listRowInsets(EdgeInsets()).listRowBackground(Color.canvasClear)
        }
    }
}

private struct SpeechLanguagePicker: View {
    let model: SettingsModel
    @Binding var language: String
    @Environment(\.locale) private var locale
    var body: some View {
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

enum AppLanguageSection {
    nonisolated static func name(of code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }
}
