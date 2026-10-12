import SwiftUI
import CassiniEngine
import CassiniNotebook

struct SpeakersView: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(VoicesStore.self) private var voices
    @Environment(ProcessingStore.self) private var processing
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NoteSpeaker?
    @State private var consent = false
    @State private var adding = false
    @State private var newName = ""
    @State private var rerun = false

    var body: some View {
        NavigationStack {
            List {
                if let note = library.note(noteID) {
                    if let failure = note.speakerAnalysisFailure { Section { Text(failure.speakerAnalysisMessage).font(.callout) } }
                    Section {
                        ForEach(note.speakers ?? []) { speaker in
                            Button { editing = speaker } label: { SpeakerRow(note: note, speaker: speaker) }
                                .accessibilityIdentifier("speaker-\(speaker.id)")
                        }
                        Button("Add a speaker", systemImage: "person.badge.plus") { newName = ""; adding = true }
                    } header: { Text("People in this recording") } footer: {
                        Text("Names apply to every passage by that speaker. Review suggested or automatically matched identities before relying on them.")
                    }
                    Section {
                        let busy = note.status == .transcribing || note.status == .queued
                        Button("Identify speakers", systemImage: "waveform.badge.magnifyingglass") {
                            if !(note.speakers ?? []).isEmpty { rerun = true } else { Task { await requestAnalysis() } }
                        }.disabled(note.transcript.isEmpty || busy || !note.audio.isPlayable)
                        if busy {
                            ProgressView(processing.state.isRunning(noteID) ? processing.state.running?.phase.message ?? "" : "")
                            Button("Cancel analysis", role: .cancel) { processing.cancel(noteID) }
                        }
                    } footer: {
                        Text("Speaker analysis runs on this device. It may take several minutes for a long recording. Keep Cassini open. Existing names remain available in transcript history when you analyze again.")
                    }
                    NavigationLink("Saved voices") { SavedVoicesView() }
                }
            }.navigationTitle("Speakers").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(item: $editing) { speaker in NameSpeakerSheet(noteID: noteID, speaker: speaker) }
                .alert("Add a speaker", isPresented: $adding) {
                    TextField("Name", text: $newName)
                    Button("Cancel", role: .cancel) {}
                    Button("Add") {
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { voices.addSpeaker(noteID: noteID, name: String(name.prefix(100))) }
                    }
                }
                .confirmationDialog("Analyze speakers again?", isPresented: $rerun, titleVisibility: .visible) {
                    Button("Analyze again") { Task { await requestAnalysis() } }
                } message: { Text("This creates a new transcript version. You can return to your current names and assignments from Transcript versions.") }
                .alert("Download speaker models?", isPresented: $consent) {
                    Button("Allow & Identify") { settings.speakerDownloadsAllowed = true; processing.enqueue(noteID, speakersOnly: true) }
                    Button("Not now", role: .cancel) {}
                } message: { Text("Cassini downloads Core ML speaker models from Hugging Face through FluidAudio. This may use several hundred MB. Audio and voiceprints stay on your device. Model downloads can be disabled in Settings.") }
        }.tint(.ember)
    }

    private func requestAnalysis() async {
        if settings.speakerDownloadsAllowed { processing.enqueue(noteID, speakersOnly: true); return }
        if await processing.speakerModelsReady() { processing.enqueue(noteID, speakersOnly: true) } else { consent = true }
    }
}

private struct SpeakerRow: View {
    let note: Note
    let speaker: NoteSpeaker
    @Environment(VoicesStore.self) private var voices
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.crop.circle").foregroundStyle(Color.ember)
                Text(speaker.name).foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            let seconds = note.transcript.filter { $0.speakerID == speaker.id }.reduce(0) { $0 + max(0, $1.end - $1.start) }
            Text("Speaks for \(TimeText.clock(seconds))").font(.caption).foregroundStyle(Color.muted)
            if let voice = voices.voice(speaker.suggestedVoiceID) {
                Text(speaker.linkedVoiceID == voice.id ? "Voice match · Review identity" : "Might be \(voice.name) · Review match").font(.caption).foregroundStyle(Color.ember)
            }
        }.padding(.vertical, 5)
    }
}
