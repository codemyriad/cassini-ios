import SwiftUI
import CassiniNotebook

struct SpeakersView: View {
    let noteID: UUID
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NoteSpeaker?
    @State private var consent = false
    @State private var adding = false
    @State private var newName = ""
    @State private var rerun = false
    private var note: Note? { store.note(noteID) }
    var body: some View {
        NavigationStack {
            List {
                if let note {
                    if let message = note.speakerAnalysisMessage { Section { Text(message).font(.callout) } }
                    Section {
                        ForEach(note.speakers ?? []) { speaker in
                            Button { editing = speaker } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Image(systemName: "person.crop.circle").foregroundStyle(Color.ember); Text(speaker.name).foregroundStyle(Color.ink); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                                    let seconds = note.transcript.filter { $0.speakerID == speaker.id }.reduce(0) { $0 + max(0, $1.end - $1.start) }
                                    Text("Speaks for \(TimeText.clock(seconds))").font(.caption).foregroundStyle(Color.muted)
                                    if let id = speaker.suggestedVoiceID, let voice = store.savedVoices.first(where: { $0.id == id }) {
                                        Text(speaker.voiceID == voice.id ? "Voice match · Review identity" : "Might be \(voice.name) · Review match").font(.caption).foregroundStyle(Color.ember)
                                    }
                                }.padding(.vertical, 5)
                            }.accessibilityIdentifier("speaker-\(speaker.id)")
                        }
                        Button("Add a speaker", systemImage: "person.badge.plus") { newName = ""; adding = true }
                    } header: { Text("People in this recording") } footer: { Text("Names apply to every passage by that speaker. Review suggested or automatically matched identities before relying on them.") }
                    Section {
                        Button("Identify speakers", systemImage: "waveform.badge.magnifyingglass") {
                            if !(note.speakers ?? []).isEmpty { rerun = true } else { requestAnalysis() }
                        }.disabled(note.transcript.isEmpty || note.status == .transcribing || note.status == .queued || note.playbackUnavailable != nil)
                        if note.status == .transcribing || note.status == .queued {
                            ProgressView(store.processingMessage)
                            Button("Cancel analysis", role: .cancel) { store.cancelTranscription(noteID) }
                        }
                    } footer: { Text("Speaker analysis runs on this device. It may take several minutes for a long recording. Keep Cassini open. Existing names remain available in transcript history when you analyze again.") }
                    NavigationLink("Saved voices") { SavedVoicesView() }
                }
            }.navigationTitle("Speakers").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $editing) { speaker in SpeakerEditor(noteID: noteID, speaker: speaker) }
                .alert("Add a speaker", isPresented: $adding) {
                    TextField("Name", text: $newName)
                    Button("Cancel", role: .cancel) {}
                    Button("Add") { let name = newName.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { store.addSpeaker(noteID: noteID, name: String(name.prefix(100))) } }
                }
                .confirmationDialog("Analyze speakers again?", isPresented: $rerun, titleVisibility: .visible) {
                    Button("Analyze again") { requestAnalysis() }
                } message: { Text("This creates a new transcript version. You can return to your current names and assignments from Transcript versions.") }
                .alert("Download speaker models?", isPresented: $consent) {
                    Button("Allow & Identify") { store.speakerDownloadsAllowed = true; store.enqueue(noteID, speakersOnly: true) }
                    Button("Not now", role: .cancel) {}
                } message: { Text("Cassini downloads Core ML speaker models from Hugging Face through FluidAudio. This may use several hundred MB. Audio and voiceprints stay on your device. Model downloads can be disabled in Settings.") }
        }.tint(.ember)
    }
    private func requestAnalysis() {
        if store.speakerDownloadsAllowed || store.speakerModelsInstalled { store.enqueue(noteID, speakersOnly: true) } else { consent = true }
    }
}

private struct SpeakerEditor: View {
    let noteID: UUID
    let speaker: NoteSpeaker
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var voiceID: UUID?
    @State private var remember = false
    @State private var renameSaved = false
    @State private var mergeTarget = ""
    @State private var merge = false
    @State private var sampleTask: Task<Void, Never>?
    init(noteID: UUID, speaker: NoteSpeaker) {
        self.noteID = noteID; self.speaker = speaker
        _name = State(initialValue: speaker.name); _voiceID = State(initialValue: speaker.voiceID)
    }
    private var canRemember: Bool { (store.speakerPrint(noteID: noteID, speakerID: speaker.id)?.speechSeconds ?? 0) >= 6 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Speaker name", text: $name).accessibilityIdentifier("speakerNameField")
                    if let note = store.note(noteID), let segment = note.transcript.first(where: { $0.speakerID == speaker.id }), note.playbackUnavailable == nil {
                        Button("Play sample", systemImage: "play.circle") {
                            sampleTask?.cancel(); store.loadPlayer(note); store.player.seek(segment.start)
                            if !store.player.isPlaying { store.togglePlayback() }
                            sampleTask = Task { try? await Task.sleep(for: .seconds(min(10, max(0.1, segment.end - segment.start)))); if !Task.isCancelled { store.player.pause() } }
                        }
                    }
                } footer: { Text("Updates every passage by this speaker in the selected transcript.") }
                if let suggested = speaker.suggestedVoiceID, let voice = store.savedVoices.first(where: { $0.id == suggested }) {
                    Section("Suggested match") {
                        Button("Use \(voice.name)") { voiceID = voice.id; name = voice.name }
                        Button("Not \(voice.name)") { store.rejectVoice(noteID: noteID, speakerID: speaker.id, voiceID: voice.id); dismiss() }
                    }
                }
                Section {
                    Picker("Saved voice", selection: $voiceID) {
                        Text("No saved voice").tag(UUID?.none)
                        ForEach(store.savedVoices) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: voiceID) { _, id in if let voice = store.savedVoices.first(where: { $0.id == id }) { name = voice.name } }
                    Toggle(voiceID == nil ? "Remember this voice" : "Improve saved voice with this recording", isOn: $remember).disabled(!canRemember)
                    if voiceID != nil { Toggle("Also rename the saved voice", isOn: $renameSaved) }
                } footer: { Text(canRemember ? "Voiceprints stay in private app storage and are never exported. Remembered voices can be suggested in future recordings." : "Run speaker analysis first. Remembering a voice needs at least six seconds of isolated speech.") }
                if let others = store.note(noteID)?.speakers?.filter({ $0.id != speaker.id }), !others.isEmpty {
                    Section("Same person detected twice?") {
                        Picker("Merge into", selection: $mergeTarget) { Text("Choose a speaker").tag(""); ForEach(others) { Text($0.name).tag($0.id) } }
                        Button("Merge speakers", role: .destructive) { merge = true }.disabled(mergeTarget.isEmpty)
                    }
                }
            }.navigationTitle("Name a speaker").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.player.pause(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if store.saveSpeaker(noteID: noteID, speakerID: speaker.id, name: name, voiceID: voiceID, remember: remember, renameSaved: renameSaved) { store.player.pause(); dismiss() }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .confirmationDialog("Merge all passages into the selected speaker?", isPresented: $merge, titleVisibility: .visible) {
                    Button("Merge speakers", role: .destructive) {
                        if store.update(noteID, { $0.mergeSpeaker(speaker.id, into: mergeTarget) }) { dismiss() }
                    }
                } message: { Text("A copy of the previous transcript is kept in Transcript versions.") }
                .onDisappear { sampleTask?.cancel(); store.player.pause() }
                .alert("Could not save speaker", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("OK") { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
        }
    }
}

struct SavedVoicesView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: SavedVoice?
    @State private var name = ""
    @State private var forgetting: SavedVoice?
    @State private var forgettingAll = false
    var body: some View {
        List {
            if store.savedVoices.isEmpty { ContentUnavailableView("No saved voices", systemImage: "person.wave.2", description: Text("Name a speaker in a recording and choose Remember this voice.")) }
            ForEach(store.savedVoices) { voice in
                VStack(alignment: .leading, spacing: 10) {
                    Text(voice.name).font(.headline)
                    Text(voice.samples.isEmpty ? "No remaining voice samples" : "\(Set(voice.samples.map(\.noteID)).count) recordings · \(TimeText.clock(voice.samples.reduce(0) { $0 + $1.print.speechSeconds })) confirmed speech").font(.caption).foregroundStyle(.secondary)
                    if let model = store.speakerModelIdentity, !voice.samples.contains(where: { $0.print.model == model }) {
                        Text("Remember this person again in a recording to use the current speaker model.").font(.caption).foregroundStyle(Color.muted)
                    }
                    HStack {
                        Button("Rename") { name = voice.name; editing = voice }.buttonStyle(.bordered)
                        Spacer()
                        Button("Forget voice", role: .destructive) { forgetting = voice }.buttonStyle(.borderless)
                    }
                }.padding(.vertical, 6)
            }
            if !store.savedVoices.isEmpty || store.voiceLibrary?.hasEvidence == true {
                Section { Button("Forget all voice data", role: .destructive) { forgettingAll = true } }
            }
            Section { Text("Forgetting a voice deletes its saved voiceprint. Names already written in transcripts remain. Permanently deleting a recording removes its samples from saved voices.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Saved voices")
            .alert("Forget all voice data?", isPresented: $forgettingAll) {
                Button("Cancel", role: .cancel) {}
                Button("Forget everyone", role: .destructive) { store.forgetAllVoices() }
            } message: { Text("Deletes saved people and all voiceprints from recordings. Existing transcript names stay unchanged. Running analysis will not restore these voiceprints.") }
            .alert("Rename saved voice", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save") { if let editing { store.renameVoice(editing.id, name: name) }; editing = nil }
            } message: { Text("Also updates linked speakers in recordings.") }
            .alert("Forget this voice?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
                Button("Cancel", role: .cancel) { forgetting = nil }
                Button("Forget voice", role: .destructive) { if let forgetting { store.forgetVoice(forgetting.id) }; forgetting = nil }
            } message: { Text("Cassini will stop suggesting this person in new recordings. Existing transcript names stay unchanged.") }
    }
}

struct TranscriptVersionsView: View {
    let noteID: UUID
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.note(noteID)?.versions ?? []) { version in
                    Button {
                        store.selectTranscriptVersion(noteID: noteID, versionID: version.id); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(version.name); Text(version.createdAt.formatted()).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if store.note(noteID)?.selectedVersionID == version.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }.navigationTitle("Transcript versions").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { store.update(noteID) { $0.saveCurrentVersion(name: "Current transcript") } }
        }
    }
}
