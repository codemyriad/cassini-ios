import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The kept versions of a note's transcript, numbered from 1. Opening it changes nothing: versions are kept where the
/// transcript changes (an edit, a merge, an analysis, a new transcription).
struct TranscriptVersionsView: View {
    let model: NoteScreenModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.clock) private var clock

    var body: some View {
        NavigationStack {
            List {
                let note = model.note
                ForEach(Array((note?.versions ?? []).enumerated()), id: \.element.id) { index, version in
                    Button { model.selectVersion(version.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SpeakersCopy.version(index + 1)).foregroundStyle(Color.ink)
                                Text(detail(version, in: note?.versions ?? []))
                                    .font(.caption).foregroundStyle(Color.muted)
                            }
                            Spacer()
                            if note?.selectedVersionID == version.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentInk)
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

    /// "Transcribed 8 Oct, 9:41 AM · 4,812 words", "Speakers merged · from version 1 · 8 Oct, 9:41 AM", or what made
    /// any other version with its date and word count, as Android's version rows read.
    private func detail(_ version: TranscriptVersion, in versions: [TranscriptVersion]) -> String {
        let date = DateLabels(calendar: calendar).shortDateTime(version.createdAt, now: clock.now)
        let words = version.segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        switch version.kind {
        case .transcription: return SpeakersCopy.versionTranscribed(at: date, words: words)
        case .mergedSpeakers:
            if let source = version.derivedFrom.flatMap({ id in versions.firstIndex { $0.id == id } }) {
                return SpeakersCopy.versionMerged(from: source + 1, at: date)
            }
            fallthrough
        default: return SpeakersCopy.versionDetail(SpeakersCopy.versionKind(version), at: date, words: words)
        }
    }
}
