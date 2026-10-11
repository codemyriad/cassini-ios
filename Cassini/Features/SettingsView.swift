import SwiftUI
import Speech
import CassiniNotebook

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var language = ""
    @State private var downloads = false
    @State private var automatic = true
    @State private var speakerDownloads = false
    @State private var identify = true
    @State private var autoNames = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        OrbitMark(size: 54)
                        Text("Your words. Your space.").font(.system(.title2, design: .serif))
                        Text("Audio and transcripts stay on this device.\nNo account. No ads. No analytics.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 18)
                }.listRowBackground(Color.clear)
                Section {
                    Picker("Language", selection: $language) {
                        if !locales.contains(where: { $0.identifier == language }) { Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(language) }
                        ForEach(locales, id: \.identifier) { locale in
                            Text((Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) + (installed.contains(locale.identifier) ? " · Installed" : "")).tag(locale.identifier)
                        }
                    }
                    Toggle("Transcribe after recording or import", isOn: $automatic)
                    Toggle("Allow speech model downloads", isOn: $downloads)
                } header: { Text("Transcription") } footer: {
                    Text("Apple’s speech models run on your device. A language model may need a download of several hundred MB. Automatic transcription starts only when downloads are allowed. Keep Cassini open while transcribing long recordings. Changing language applies to new transcription jobs.")
                }
                Section {
                    Toggle("Identify speakers after transcription", isOn: $identify)
                    Toggle("Allow speaker model downloads", isOn: $speakerDownloads)
                    Toggle("Automatically name strong voice matches", isOn: $autoNames)
                    LabeledContent("Speaker models", value: store.speakerModelsInstalled ? "Installed" : "Not downloaded")
                    NavigationLink("Saved voices") { SavedVoicesView() }
                } header: { Text("Speakers") } footer: { Text("Core ML speaker models run locally. Enabling downloads allows Cassini to fetch several hundred MB from Hugging Face through FluidAudio. Voiceprints stay in private app storage, outside system backups and exports. Automatic naming is off by default. Matches can be wrong; review names. Disabling downloads still permits use of installed models. Only voices you explicitly remember become recognition samples.") }
                Section("Recording") {
                    LabeledContent("Saved format", value: "AAC · M4A")
                    LabeledContent("Capture quality", value: "48 kHz · 16-bit · Mono")
                    Text("Capture is saved in original quality first, then compressed to M4A. If compression is interrupted, the original recording is kept.").font(.footnote).foregroundStyle(.secondary)
                    Label("Continues with the screen locked", systemImage: "lock")
                    Button("Microphone permissions") { openSystemSettings() }
                }
                Section {
                    LabeledContent("Recordings", value: "\(store.notes.filter { $0.trashedAt == nil }.count)")
                    LabeledContent("Audio duration", value: TimeText.clock(store.notes.reduce(0) { $0 + $1.duration }))
                    Text("Recordings use your device’s protected app storage and may be included in your system backups. Exports go only to the destinations you choose.").font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Your library") } footer: { Text("Recently Deleted keeps recordings for 30 days. Expired recordings are removed when Cassini next opens.") }
                Section("About Cassini") {
                    LabeledContent("Version", value: "0.1.0")
                    Text("Made for listening closely.").font(.system(.body, design: .serif))
                    Text("On-device speaker analysis, editable speaker names, saved voices, and transcript history. Speaker matches are suggestions, and may need correction.").font(.footnote).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background(Color.paper)
                .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task {
                    language = store.language; downloads = store.downloadsAllowed; automatic = store.autoTranscribe
                    speakerDownloads = store.speakerDownloadsAllowed; identify = store.identifySpeakers; autoNames = store.automaticallyNameVoices
                    locales = await SpeechTranscriber.supportedLocales.sorted {
                        (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
                    }
                    installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
                }
                .onChange(of: language) { _, value in if !value.isEmpty { store.language = value } }
                .onChange(of: downloads) { _, value in store.downloadsAllowed = value }
                .onChange(of: speakerDownloads) { _, value in store.speakerDownloadsAllowed = value }
                .onChange(of: autoNames) { _, value in store.automaticallyNameVoices = value }
                .onChange(of: identify) { _, value in store.identifySpeakers = value }
                .onChange(of: automatic) { _, value in store.autoTranscribe = value }
        }
    }
}

struct TrashView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: Note?
    @State private var emptying = false
    private var notes: [Note] { store.notes.filter { $0.trashedAt != nil }.sorted { $0.trashedAt! < $1.trashedAt! } }
    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty { ContentUnavailableView("Nothing here", systemImage: "trash", description: Text("Deleted recordings can be restored for 30 days.")) }
                else {
                    List {
                        Section {
                            ForEach(notes) { note in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(note.title).font(.headline)
                                    if let date = note.trashedAt { Text("Deleted \(date.formatted(date: .abbreviated, time: .omitted)) · \(TrashPolicy.daysLeft(since: date)) days left").font(.caption).foregroundStyle(.secondary) }
                                    Text(TimeText.clock(note.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Restore", systemImage: "arrow.uturn.backward") { store.restore(note.id) }.buttonStyle(.bordered)
                                        Spacer()
                                        Button("Delete forever", systemImage: "trash", role: .destructive) { pendingDelete = note }.buttonStyle(.borderless)
                                    }
                                }.padding(.vertical, 8)
                            }
                        } footer: { Text("Recordings expire after 30 days. Permanent deletion removes audio, transcripts, and voice samples from this recording.") }
                    }.scrollContentBackground(.hidden)
                }
            }.background(Color.paper).navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .toolbar { ToolbarItem(placement: .topBarLeading) { if !notes.isEmpty { Button("Empty", role: .destructive) { emptying = true } } } }
                .task { store.purgeExpiredTrash() }
                .alert("Empty Recently Deleted?", isPresented: $emptying) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete all forever", role: .destructive) { store.emptyTrash() }
                } message: { Text("Permanently deletes all \(notes.count) recordings in Recently Deleted and their voice samples. This cannot be undone.") }
                .alert("Delete recording forever?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                    Button("Delete forever", role: .destructive) { if let note = pendingDelete { store.deletePermanently(note.id) }; pendingDelete = nil }
                } message: { Text("“\(pendingDelete?.title ?? "")” and its transcript will be permanently deleted. This cannot be undone.") }
        }
    }
}
