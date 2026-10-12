import SwiftUI
import CassiniNotebook

struct NameSpeakerSheet: View {
    let noteID: UUID
    let speaker: NoteSpeaker
    @Environment(LibraryStore.self) private var library
    @Environment(VoicesStore.self) private var voices
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var voiceID: UUID?
    @State private var remember = false
    @State private var renameSaved = false
    @State private var mergeTarget = ""
    @State private var merge = false
    @State private var saveError: String?

    init(noteID: UUID, speaker: NoteSpeaker) {
        self.noteID = noteID; self.speaker = speaker
        _name = State(initialValue: speaker.name); _voiceID = State(initialValue: speaker.linkedVoiceID)
    }

    private var note: Note? { library.note(noteID) }
    private var canRemember: Bool { (voices.speakerPrint(noteID: noteID, speakerID: speaker.id)?.speechSeconds ?? 0) >= 6 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Speaker name", text: $name).accessibilityIdentifier("speakerNameField")
                    if let note, let segment = note.transcript.first(where: { $0.speakerID == speaker.id }), note.audio.isPlayable {
                        Button("Play sample", systemImage: "play.circle") {
                            playback.playSample(note, from: segment.start, duration: min(10, max(0.1, segment.end - segment.start)))
                        }
                    }
                } footer: { Text("Updates every passage by this speaker in the selected transcript.") }
                if let voice = voices.voice(speaker.suggestedVoiceID) {
                    Section("Suggested match") {
                        Button("Use \(voice.name)") { voiceID = voice.id; name = voice.name }
                        Button("Not \(voice.name)") { voices.rejectVoice(noteID: noteID, speakerID: speaker.id, voiceID: voice.id); dismiss() }
                    }
                }
                Section {
                    Picker("Saved voice", selection: $voiceID) {
                        Text("No saved voice").tag(UUID?.none)
                        ForEach(voices.savedVoices) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: voiceID) { _, id in if let voice = voices.voice(id) { name = voice.name } }
                    Toggle(voiceID == nil ? "Remember this voice" : "Improve saved voice with this recording", isOn: $remember).disabled(!canRemember)
                    if voiceID != nil { Toggle("Also rename the saved voice", isOn: $renameSaved) }
                } footer: {
                    Text(canRemember ? "Voiceprints stay in private app storage and are never exported. Remembered voices can be suggested in future recordings." : "Run speaker analysis first. Remembering a voice needs at least six seconds of isolated speech.")
                }
                if let others = note?.speakers?.filter({ $0.id != speaker.id }), !others.isEmpty {
                    Section("Same person detected twice?") {
                        Picker("Merge into", selection: $mergeTarget) { Text("Choose a speaker").tag(""); ForEach(others) { Text($0.name).tag($0.id) } }
                        Button("Merge speakers", role: .destructive) { merge = true }.disabled(mergeTarget.isEmpty)
                    }
                }
            }.navigationTitle("Name a speaker").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { playback.pause(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .confirmationDialog("Merge all passages into the selected speaker?", isPresented: $merge, titleVisibility: .visible) {
                    Button("Merge speakers", role: .destructive) {
                        let source = speaker.id, target = mergeTarget
                        if library.update(noteID, { $0.mergeSpeaker(source, into: target) }) { dismiss() }
                    }
                } message: { Text("A copy of the previous transcript is kept in Transcript versions.") }
                .onDisappear { playback.cancelSample(); playback.pause() }
                .alert("Could not save speaker", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                    Button("OK") { saveError = nil }
                } message: { Text(saveError ?? "") }
        }
    }

    private func save() {
        do {
            try voices.saveSpeaker(noteID: noteID, speakerID: speaker.id, name: name, voiceID: voiceID, remember: remember, renameSaved: renameSaved)
            playback.pause(); dismiss()
        } catch {
            saveError = error.message
        }
    }
}
