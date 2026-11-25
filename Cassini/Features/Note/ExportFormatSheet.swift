import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Both entry points use this selector; the caller starts sharing only after dismissal completes.
struct ExportFormatSheet: View {
    let note: Note
    let jobPending: Bool
    let confirm: (ExportSheetState.Choice) -> Void
    @State private var selection: ExportSheetState.Choice?
    @State private var cassiniBytes: Int64?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.clock) private var clock
    @Environment(\.locale) private var locale
    @Environment(LibraryStore.self) private var library

    private var state: ExportSheetState { ExportSheetState(note: note, jobPending: jobPending) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 3) {
                        Text(note.title)
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if !metaLine.isEmpty {
                            Text(metaLine)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Color.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.canvasClear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 12, trailing: 20))
                }
                Section {
                    ForEach(state.primary) { row($0) }
                }
                .accessibilityLabel(ExportPhase2Copy.formatGroup)
                if !state.moreFormats.isEmpty {
                    Section {
                        ForEach(state.moreFormats) { row($0) }
                    } header: {
                        Text(ExportPhase2Copy.otherFormats)
                    }
                }
                if state.audioOnly {
                    Section {
                        Text(ExportPhase2Copy.audioOnlyNote).foregroundStyle(Color.muted)
                    }
                }
            }
            .accessibilityIdentifier("exportFormats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NoteCopy.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ExportPhase2Copy.exportButton) {
                        let chosen = selection ?? state.selection
                        guard (state.primary + state.moreFormats).contains(chosen) else { return }
                        confirm(chosen)
                        dismiss()
                    }
                    .accessibilityIdentifier("exportConfirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: note.id) {
            let note = self.note
            let audioURL = library.audioURL(note)
            cassiniBytes = await Self.estimateCassiniBytes(note: note, audioURL: audioURL)
        }
    }

    private var metaLine: String {
        let subtitle = NoteSubtitle.of(note, mode: .reading, now: clock.now, calendar: calendar)
            .map { NoteCopy.subtitle($0, calendar: calendar) }
        let speakers = Set(note.transcript.compactMap(\.speakerID).map { Data($0.utf8) }).count
        let speakerText = speakers > 0 ? LibraryPhase1Copy.speakerCount(speakers) : nil
        return [subtitle, speakerText].compactMap { $0 }.joined(separator: " · ")
    }

    @concurrent private static func estimateCassiniBytes(note: Note, audioURL: URL?) async -> Int64? {
        ExportSizeEstimate.cassiniBytes(note: note, audioURL: audioURL)
    }

    private func row(_ choice: ExportSheetState.Choice) -> some View {
        Button { selection = choice } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // Explicit ink keeps Form buttons from resolving text as levels of the accent tint.
                    rowTitle(choice)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(description(choice))
                        .font(.footnote)
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if (selection ?? state.selection) == choice {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentInk)
                }
            }
        }
        .accessibilityIdentifier("exportChoice-\(choice.rawValue)")
        .accessibilityAddTraits((selection ?? state.selection) == choice ? .isSelected : [])
    }

    private func rowTitle(_ choice: ExportSheetState.Choice) -> Text {
        let name = Text(title(choice)).foregroundStyle(Color.ink)
        guard let suffix = typeSuffix(choice) else { return name }
        return name + Text(verbatim: " ") + Text(suffix).font(.footnote).foregroundStyle(Color.muted)
    }

    private func typeSuffix(_ choice: ExportSheetState.Choice) -> String? {
        switch choice {
        case .cassiniFile:
            if let cassiniBytes, cassiniBytes > 0 {
                return ExportPhase2Copy.typeWithSize(".opus", size: SizeCopy.text(cassiniBytes, locale: locale))
            }
            return ".opus"
        case .markdown: return ".md"
        case .plainText: return ".txt"
        case .srt: return ".srt"
        case .vtt: return ".vtt"
        case .originalAudio: return nil
        }
    }

    private func title(_ choice: ExportSheetState.Choice) -> String {
        switch choice {
        case .cassiniFile: ExportPhase2Copy.cassiniFile
        case .markdown: ExportPhase2Copy.markdown
        case .plainText: ExportPhase2Copy.plainText
        case .srt: ExportPhase2Copy.subtitles
        case .vtt: ExportPhase2Copy.subtitles
        case .originalAudio: ExportPhase2Copy.originalAudio
        }
    }

    private func description(_ choice: ExportSheetState.Choice) -> String {
        switch choice {
        case .cassiniFile: ExportPhase2Copy.cassiniDescription
        case .markdown: ExportPhase2Copy.markdownDescription
        case .plainText: ExportPhase2Copy.plainTextDescription
        case .srt: ExportPhase2Copy.srtDescription
        case .vtt: ExportPhase2Copy.vttDescription
        case .originalAudio: ExportPhase2Copy.originalDescription
        }
    }
}
