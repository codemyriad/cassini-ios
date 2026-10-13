import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The speakers of a note (an iOS screen; Android reaches naming from the transcript only): each speaker opens Name a
/// speaker, Identify speakers runs the analysis again, and Saved voices is one tap away. Without consent for the speaker
/// models, Identify speakers opens the model download screen, the only place consent is given.
struct SpeakersView: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(VoicesStore.self) private var voices
    @Environment(ProcessingStore.self) private var processing
    @Environment(JobProgress.self) private var progress
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.dismiss) private var dismiss
    @State private var naming: SpeakerRef?
    @State private var adding = false
    @State private var newName = ""
    @State private var rerun = false

    var body: some View {
        NavigationStack {
            List {
                if let note = library.note(noteID) {
                    if let failure = note.speakerAnalysisFailure { Section { Text(failure.speakerAnalysisMessage).font(.callout) } }
                    Section {
                        let stats = SpeakerStats.of(note.transcript)
                        ForEach(Array((note.speakers ?? []).enumerated()), id: \.element.id) { index, speaker in
                            let stat = stats.first { $0.speakerID == speaker.id }
                            Button { naming = SpeakerRef(id: speaker.id) } label: {
                                SpeakerRow(speaker: speaker, ordinal: stat?.ordinal ?? index, speakingTime: stat?.speakingTime ?? 0)
                            }
                            .accessibilityIdentifier("speaker-\(speaker.id)")
                        }
                        Button(SpeakersCopy.addSpeaker, systemImage: "person.badge.plus") { newName = ""; adding = true }
                    } header: { Text(SpeakersCopy.peopleInRecording) } footer: { Text(SpeakersCopy.speakersFooter) }
                    Section {
                        let busy = note.status == .transcribing || note.status == .queued
                        Button(SpeakersCopy.identifySpeakers, systemImage: "waveform.badge.magnifyingglass") {
                            if !(note.speakers ?? []).isEmpty { rerun = true } else { Task { await requestAnalysis() } }
                        }.disabled(note.transcript.isEmpty || busy || !note.audio.isPlayable)
                        if busy {
                            ProgressView(progress.processingPhase(for: noteID)?.message ?? "")
                            Button(SpeakersCopy.cancelAnalysis, role: .cancel) { processing.stop(noteID) }
                        }
                    } footer: { Text(SpeakersCopy.analysisFooter) }
                    NavigationLink(SpeakersCopy.voices) { SavedVoicesView() }
                }
            }
            .navigationTitle(SpeakersCopy.speakersTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(SpeakersCopy.done) { dismiss() } } }
            .sheet(item: $naming) { NameSpeakerSheet(noteID: noteID, speakerID: $0.id) }
            .alert(SpeakersCopy.addSpeaker, isPresented: $adding) {
                TextField(SpeakersCopy.nameField, text: $newName)
                Button(SpeakersCopy.cancel, role: .cancel) {}
                Button(SpeakersCopy.add) { voices.addSpeaker(noteID: noteID, name: newName) }
            }
            .confirmationDialog(SpeakersCopy.analyzeAgainTitle, isPresented: $rerun, titleVisibility: .visible) {
                Button(SpeakersCopy.analyzeAgain) { Task { await requestAnalysis() } }
            } message: { Text(SpeakersCopy.analyzeAgainBody) }
        }
        .tint(.ember)
    }

    /// Queues the speakers-only job; without consent the sheet gives way to the model download screen.
    private func requestAnalysis() async {
        switch await processing.transcribe(noteID, kind: .speakersOnly) {
        case .needsConsent:
            dismiss()
            router.push(.modelDownload(noteID: noteID))
        case .refused(let refusal): errors.present(refusal.message)
        case .queued: break
        }
    }
}

/// A speaker id the naming sheet opens for.
struct SpeakerRef: Identifiable, Hashable {
    let id: String
}

private struct SpeakerRow: View {
    let speaker: NoteSpeaker
    let ordinal: Int
    let speakingTime: Double
    @Environment(VoicesStore.self) private var voices

    var body: some View {
        HStack(spacing: 12) {
            SpeakerAvatar(speaker: speaker.name, ordinal: ordinal)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(speaker.name).foregroundStyle(Color.ink)
                    if case .auto(let id, _) = speaker.match, let voice = voices.voice(id), NameMatch.same(voice.name, speaker.name) {
                        Text(SpeakersCopy.auto).font(.caption2.weight(.semibold)).foregroundStyle(Color.toneInfo)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Tone.info.background, in: Capsule())
                    }
                }
                Text(SpeakersCopy.speaksFor(speakingTime)).font(.caption).foregroundStyle(Color.muted)
                if case .suggested(let id, _) = speaker.match, let voice = voices.voice(id) {
                    Text(SpeakersCopy.mightBe(voice.name)).font(.caption).foregroundStyle(Color.ember)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.muted)
        }
        .padding(.vertical, 4)
    }
}
