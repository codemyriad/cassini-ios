import SwiftUI
import CassiniEngine

struct VoiceSetupSection: View {
    @Environment(SettingsStore.self) private var settings
    var body: some View {
        if !settings.voiceSetupAnswered {
            Section {
                Text(Wave6Copy.voicesSetupTitle).font(.headline)
                Text(Wave6Copy.voicesSetupBody)
                Text(Wave6Copy.voicesSetupPrivacyPhone).font(.footnote).foregroundStyle(Color.muted)
                Button(Wave6Copy.voicesSetupEnable) { settings.answerVoiceSetup(enable: true) }
                Button(Wave6Copy.commonNotNow) { settings.answerVoiceSetup(enable: false) }
            }
            .accessibilityIdentifier("voiceSetupQuestion")
        }
    }
}

struct VoiceEnrollmentView: View {
    @Environment(VoiceEnrollmentAdapter.self) private var enrollment
    @Environment(VoicesStore.self) private var voices
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Wave6Copy.voicesEnrollInstructions)
                    TextField(SpeakersCopy.nameField, text: $name).textInputAutocapitalization(.words)
                }
                Section {
                    Text(Wave6Copy.voicesEnrollTestPhrase)
                    Text(Wave6Copy.voicesEnrollFromTranscriptHint).font(.footnote).foregroundStyle(Color.muted)
                } header: { Text(Wave6Copy.voicesEnrollTestPhraseLabel) }
                Section {
                    Button(enrollment.recording ? Wave6Copy.commonStop : Wave6Copy.voicesEnrollRecord) {
                        Task {
                            do {
                                if enrollment.recording { try await enrollment.finish() }
                                else { try await enrollment.start() }
                            } catch { errors.present(error.localizedDescription) }
                        }
                    }
                    .disabled(enrollment.busy)
                    if enrollment.recording { Text(Wave6Copy.voicesEnrollRecording) }
                    if let failure = enrollment.failure { Text(failure).foregroundStyle(Color.toneError) }
                    if enrollment.tooShort { Text(Wave6Copy.voicesEnrollTooShort).foregroundStyle(Color.toneWarn) }
                    if enrollment.print != nil { Text(Wave6Copy.voicesEnrollReady) }
                    Button(Wave6Copy.voicesEnrollSave) {
                        Task {
                            do {
                                try await enrollment.save(name: name, voices: voices)
                                dismiss()
                            } catch { errors.present(error.localizedDescription) }
                        }
                    }
                    .disabled(enrollment.print == nil || enrollment.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(Wave6Copy.voicesEnrollTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Wave6Copy.commonCancel) { dismiss() }.disabled(enrollment.busy) } }
            .interactiveDismissDisabled(enrollment.busy)
            .onDisappear { Task { await enrollment.cancel() } }
        }
    }
}
