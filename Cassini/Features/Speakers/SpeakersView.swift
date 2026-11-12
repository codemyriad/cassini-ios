import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The speakers of a note (an iOS screen; Android reaches naming from the transcript only): each speaker opens Name a
/// speaker, Identify speakers runs the analysis again, and Saved voices is one tap away. Without consent for the speaker
/// models, Identify speakers opens the model download screen, the only place consent is given. Its actions go through
/// the Note screen's model, so the transcript's read-only rule holds here too: while a job is pending (or a document's
/// trust is not verified) the speakers and Add a speaker are disabled, and Identify speakers waits.
struct SpeakersView: View {
    let model: NoteScreenModel
    @Environment(JobProgress.self) private var progress
    @Environment(\.dismiss) private var dismiss
    @State private var naming: SpeakerRef?
    @State private var adding = false
    @State private var newName = ""
    @State private var rerun = false

    private var noteID: UUID { model.noteID }

    var body: some View {
        NavigationStack {
            List {
                if let note = model.note {
                    let readOnly = model.readOnly
                    if let failure = note.speakerAnalysisFailure { Section { Text(failure.speakerAnalysisMessage).font(.callout) } }
                    Section {
                        let stats = SpeakerStats.of(note.transcript)
                        let speaking = stats.filter { $0.wordCount > 0 }
                        let spoken = Set(speaking.map(\.speakerID))
                        let order = speaking.map(\.speakerID) + (note.speakers ?? []).map(\.id).filter { !spoken.contains($0) }
                        let catalog = note.speakers ?? []
                        let palette = catalog.contains { $0.colourIndex == nil }
                            ? Note.assignColourIndices(catalog, order: SpeakerColourOrder.segments(note.transcript)) : catalog
                        let tints = SpeakerTint.assign(order, speakers: palette)
                        ForEach(Array((note.speakers ?? []).enumerated()), id: \.element.id) { index, speaker in
                            let stat = stats.first { $0.speakerID == speaker.id }
                            Button { naming = SpeakerRef(id: speaker.id) } label: {
                                SpeakerRow(speaker: speaker, ordinal: stat?.ordinal ?? index, tint: tints[speaker.id] ?? .stone, speakingTime: stat?.speakingTime ?? 0)
                            }
                            .accessibilityIdentifier("speaker-\(speaker.id)")
                        }
                        Button(SpeakersCopy.addSpeaker, systemImage: "person.badge.plus") { newName = ""; adding = true }
                            .accessibilityIdentifier("addSpeaker")
                    } header: { Text(SpeakersCopy.peopleInRecording) } footer: { Text(SpeakersCopy.speakersFooter) }
                    .disabled(readOnly != nil)
                    Section {
                        Button(SpeakersCopy.identifySpeakers, systemImage: "waveform.badge.magnifyingglass") {
                            if !(note.speakers ?? []).isOneVoice { rerun = true } else { Task { await model.identifySpeakers() } }
                        }
                        .disabled(note.transcript.isEmpty || readOnly != nil || !note.audio.isPlayable)
                        .accessibilityIdentifier("identifySpeakers")
                        if readOnly == .jobPending {
                            ProgressView(progress.processingPhase(for: noteID)?.message ?? "")
                            Button(SpeakersCopy.cancelAnalysis, role: .cancel) { model.stopJob() }
                        }
                    } footer: { Text(SpeakersCopy.analysisFooter) }
                    NavigationLink(SpeakersCopy.voices) { SavedVoicesView() }
                }
            }
            .paperListBackground()
            .navigationTitle(SpeakersCopy.speakersTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(SpeakersCopy.done) { dismiss() } } }
            .sheet(item: $naming) { NameSpeakerSheet(model: model.naming($0.id)) }
            .alert(SpeakersCopy.addSpeaker, isPresented: $adding) {
                TextField(SpeakersCopy.nameField, text: $newName)
                Button(SpeakersCopy.cancel, role: .cancel) {}
                Button(SpeakersCopy.add) { model.addSpeaker(named: newName) }
            }
            .confirmationDialog(SpeakersCopy.analyzeAgainTitle, isPresented: $rerun, titleVisibility: .visible) {
                Button(SpeakersCopy.analyzeAgain) { Task { await model.identifySpeakers() } }
            } message: { Text(SpeakersCopy.analyzeAgainBody) }
        }
        .tint(.accent)
    }
}

/// A speaker id the naming sheet opens for.
struct SpeakerRef: Identifiable, Hashable {
    let id: String
}

private struct SpeakerRow: View {
    let speaker: NoteSpeaker
    let ordinal: Int
    let tint: SpeakerTint
    let speakingTime: Double
    @Environment(VoicesStore.self) private var voices

    var body: some View {
        HStack(spacing: 12) {
            SpeakerAvatar(name: speaker.name, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(NoteCopy.speakerLabel(speaker.name, id: speaker.id, ordinal: ordinal)).foregroundStyle(Color.ink)
                    if case .auto(let id, _) = speaker.match, let voice = voices.voice(id), NameMatch.same(voice.name, speaker.name) {
                        Text(SpeakersCopy.auto).font(.caption2.weight(.semibold)).foregroundStyle(Color.toneInfo)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.ink.opacity(0.1), in: Capsule())
                    }
                }
                Text(SpeakersCopy.speaksFor(speakingTime)).font(.caption).foregroundStyle(Color.muted)
                if case .suggested(let id, _) = speaker.match, let voice = voices.voice(id) {
                    Text(SpeakersCopy.mightBe(voice.name)).font(.caption).foregroundStyle(Color.accentInk)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.muted)
        }
        .padding(.vertical, 4)
    }
}
