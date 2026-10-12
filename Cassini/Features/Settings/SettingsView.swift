import SwiftUI
import Speech
import CassiniEngine
import CassiniNotebook

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(ProcessingStore.self) private var processing
    @Environment(NoticesStore.self) private var notices
    @Environment(\.locale) private var locale
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var speakerModelsInstalled = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                VStack(spacing: 12) {
                    OrbitMark(size: 54)
                    Text("Your words. Your space.").font(.system(.title2, design: .serif))
                    Text("Audio and transcripts stay on this device.\nNo account. No ads. No analytics.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            }.listRowBackground(Color.clear)
            let banners = notices.settingsBanners
            if !banners.isEmpty {
                Section {
                    BannerList(specs: banners, onAction: { spec, action in notices.perform(action, on: spec) },
                               onDismiss: notices.dismiss)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section {
                Picker("Language", selection: $settings.speechLanguage) {
                    if !locales.contains(where: { $0.identifier(.bcp47) == settings.speechLanguage }) {
                        Text(name(of: settings.speechLanguage)).tag(settings.speechLanguage)
                    }
                    ForEach(locales, id: \.self) { candidate in
                        let id = candidate.identifier(.bcp47)
                        Text(name(of: id) + (installed.contains(id) ? " · Installed" : "")).tag(id)
                    }
                }
                Toggle("Transcribe after recording or import", isOn: $settings.autoTranscribe)
                Toggle("Allow speech model downloads", isOn: $settings.downloadsAllowed)
            } header: { Text("Transcription") } footer: {
                Text("Apple’s speech models run on your device. A language model may need a download of several hundred MB. Automatic transcription starts only when downloads are allowed. Keep Cassini open while transcribing long recordings. Changing language applies to new transcription jobs.")
            }
            Section {
                Toggle("Identify speakers after transcription", isOn: $settings.identifySpeakers)
                Toggle("Allow speaker model downloads", isOn: $settings.speakerDownloadsAllowed)
                Toggle("Automatically name strong voice matches", isOn: $settings.automaticallyNameVoices)
                LabeledContent("Speaker models", value: speakerModelsInstalled ? "Installed" : "Not downloaded")
                Button("Saved voices") { router.push(.savedVoices) }
            } header: { Text("Speakers") } footer: {
                Text("Core ML speaker models run locally. Enabling downloads allows Cassini to fetch several hundred MB from Hugging Face through FluidAudio. Voiceprints stay in private app storage, outside system backups and exports. Automatic naming is off by default. Matches can be wrong; review names. Disabling downloads still permits use of installed models. Only voices you explicitly remember become recognition samples.")
            }
            Section("Recording") {
                LabeledContent("Saved format", value: "AAC · M4A")
                LabeledContent("Capture quality", value: "48 kHz · 16-bit · Mono")
                Text("Capture is saved in original quality first, then compressed to M4A. If compression is interrupted, the original recording is kept.").font(.footnote).foregroundStyle(.secondary)
                Label("Continues with the screen locked", systemImage: "lock")
                Button("Microphone permissions") { openSystemSettings() }
            }
            Section {
                LabeledContent("Recordings", value: "\(library.notes.filter { $0.trashedAt == nil }.count)")
                LabeledContent("Audio duration", value: TimeText.clock(library.notes.reduce(0) { $0 + $1.duration }))
                Text("Recordings use your device’s protected app storage and may be included in your system backups. Exports go only to the destinations you choose.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Your library") } footer: { Text("Recently Deleted keeps recordings for 30 days. Expired recordings are removed when Cassini next opens.") }
            Section("About Cassini") {
                LabeledContent("Version", value: "0.1.0")
                Text("Made for listening closely.").font(.system(.body, design: .serif))
                Text("On-device speaker analysis, editable speaker names, saved voices, and transcript history. Speaker matches are suggestions, and may need correction.").font(.footnote).foregroundStyle(.secondary)
                Button("Licenses") { router.push(.licenses) }
            }
        }
        .scrollContentBackground(.hidden).background(Color.paper)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .task {
            locales = await SpeechTranscriber.supportedLocales.sorted { name(of: $0.identifier(.bcp47)) < name(of: $1.identifier(.bcp47)) }
            installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
            speakerModelsInstalled = await processing.speakerModelsReady()
        }
    }

    private func name(of identifier: String) -> String { locale.localizedString(forIdentifier: identifier) ?? identifier }
}
