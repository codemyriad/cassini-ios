import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Consent for downloading Apple's speech model, optionally for one note.
struct ModelDownloadView: View {
    let noteID: UUID?
    @Environment(SettingsStore.self) private var settings
    @Environment(ProcessingStore.self) private var processing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("Transcribe on this device").font(.system(.title, design: .serif)).foregroundStyle(Color.ink)
            Text("Cassini uses Apple’s on-device speech model. If needed, iOS will download a language model, which may use several hundred MB. Your audio is never sent for transcription. You can change this in Settings.")
                .foregroundStyle(Color.muted)
            Spacer()
            Button(noteID == nil ? "Allow downloads" : "Download and transcribe") {
                settings.recordConsent()
                if let noteID { processing.enqueue(noteID) }
                dismiss()
            }.buttonStyle(PrimaryButtonStyle())
            Button("Not now — keep the audio") { settings.recordDeclined(); dismiss() }
                .frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
        }
        .padding(Spacing.gutter).frame(maxWidth: ReadableWidth.note).frame(maxWidth: .infinity)
        .background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
    }
}
