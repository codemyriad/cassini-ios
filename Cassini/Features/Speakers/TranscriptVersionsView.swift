import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The kept versions of a note's transcript, numbered from 1. Opening it changes nothing: versions are kept where the
/// transcript changes (an edit, a merge, an analysis, a new transcription).
struct TranscriptVersionsView: View {
    let model: NoteScreenModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let note = model.note
                ForEach(Array((note?.versions ?? []).enumerated()), id: \.element.id) { index, version in
                    Button { model.selectVersion(version.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SpeakersCopy.version(index + 1)).foregroundStyle(Color.ink)
                                Text(verbatim: "\(SpeakersCopy.versionKind(version)) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(Color.muted)
                            }
                            Spacer()
                            if note?.selectedVersionID == version.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.ember)
                            }
                        }
                    }
                    .accessibilityAddTraits(note?.selectedVersionID == version.id ? .isSelected : [])
                }
            }
            .paperListBackground()
            .navigationTitle(SpeakersCopy.versionsTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(SpeakersCopy.done) { dismiss() } } }
        }
    }
}
