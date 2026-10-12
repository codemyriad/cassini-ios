import SwiftUI
import CassiniNotebook

struct TranscriptVersionsView: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(VoicesStore.self) private var voices
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(library.note(noteID)?.versions ?? []) { version in
                    Button {
                        voices.selectTranscriptVersion(noteID: noteID, versionID: version.id); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(version.name); Text(version.createdAt.formatted()).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if library.note(noteID)?.selectedVersionID == version.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }.navigationTitle("Transcript versions").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { library.update(noteID) { $0.saveCurrentVersion(name: "Current transcript") } }
        }
    }
}
