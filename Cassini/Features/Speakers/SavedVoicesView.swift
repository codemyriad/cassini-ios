import SwiftUI
import CassiniEngine
import CassiniNotebook

struct SavedVoicesView: View {
    @Environment(VoicesStore.self) private var voices
    @Environment(SettingsStore.self) private var settings
    @State private var editing: SavedVoice?
    @State private var name = ""
    @State private var forgetting: SavedVoice?
    @State private var forgettingAll = false

    var body: some View {
        List {
            if voices.savedVoices.isEmpty {
                ContentUnavailableView("No saved voices", systemImage: "person.wave.2", description: Text("Name a speaker in a recording and choose Remember this voice."))
            }
            ForEach(voices.savedVoices) { voice in
                VStack(alignment: .leading, spacing: 10) {
                    Text(voice.name).font(.headline)
                    Text(voice.samples.isEmpty ? "No remaining voice samples" : "\(Set(voice.samples.map(\.noteID)).count) recordings · \(TimeText.clock(voice.samples.reduce(0) { $0 + $1.print.speechSeconds })) confirmed speech")
                        .font(.caption).foregroundStyle(.secondary)
                    if let model = settings.speakerModelIdentity, !voice.samples.contains(where: { $0.print.model == model }) {
                        Text("Remember this person again in a recording to use the current speaker model.").font(.caption).foregroundStyle(Color.muted)
                    }
                    HStack {
                        Button("Rename") { name = voice.name; editing = voice }.buttonStyle(.bordered)
                        Spacer()
                        Button("Forget voice", role: .destructive) { forgetting = voice }.buttonStyle(.borderless)
                    }
                }.padding(.vertical, 6)
            }
            if !voices.savedVoices.isEmpty || voices.hasEvidence {
                Section { Button("Forget all voice data", role: .destructive) { forgettingAll = true } }
            }
            Section {
                Text("Forgetting a voice deletes its saved voiceprint. Names already written in transcripts remain. Permanently deleting a recording removes its samples from saved voices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Saved voices")
            .alert("Forget all voice data?", isPresented: $forgettingAll) {
                Button("Cancel", role: .cancel) {}
                Button("Forget everyone", role: .destructive) { voices.forgetAllVoices() }
            } message: { Text("Deletes saved people and all voiceprints from recordings. Existing transcript names stay unchanged. Running analysis will not restore these voiceprints.") }
            .alert("Rename saved voice", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save") { if let editing { voices.renameVoice(editing.id, name: name) }; editing = nil }
            } message: { Text("Also updates linked speakers in recordings.") }
            .alert("Forget this voice?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
                Button("Cancel", role: .cancel) { forgetting = nil }
                Button("Forget voice", role: .destructive) { if let forgetting { voices.forgetVoice(forgetting.id) }; forgetting = nil }
            } message: { Text("Cassini will stop suggesting this person in new recordings. Existing transcript names stay unchanged.") }
    }
}
