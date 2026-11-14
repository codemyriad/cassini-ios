import SwiftUI
import CassiniNotebook

/// Both entry points use this selector; the caller starts sharing only after dismissal completes.
struct ExportFormatSheet: View {
    let note: Note
    let jobPending: Bool
    let confirm: (ExportSheetState.Choice) -> Void
    @State private var selection: ExportSheetState.Choice?
    @State private var expanded = false
    @Environment(\.dismiss) private var dismiss

    private var state: ExportSheetState { ExportSheetState(note: note, jobPending: jobPending) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(state.primary) { row($0) }
                    if !state.moreFormats.isEmpty {
                        DisclosureGroup(ExportPhase2Copy.moreFormats, isExpanded: $expanded) {
                            ForEach(state.moreFormats) { row($0) }
                        }
                    }
                }
                .accessibilityLabel(ExportPhase2Copy.formatGroup)
                if state.audioOnly { Text(ExportPhase2Copy.audioOnlyNote) }
            }
            .navigationTitle(ExportPhase2Copy.title.replacingOccurrences(of: "{title}", with: note.title))
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
                }
            }
        }
    }

    private func row(_ choice: ExportSheetState.Choice) -> some View {
        Button { selection = choice } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title(choice))
                    Text(description(choice)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if (selection ?? state.selection) == choice { Image(systemName: "checkmark") }
            }
            .foregroundStyle(.primary)
        }
        .accessibilityAddTraits((selection ?? state.selection) == choice ? .isSelected : [])
    }

    private func title(_ choice: ExportSheetState.Choice) -> String {
        switch choice {
        case .cassiniFile: ExportPhase2Copy.cassiniFile
        case .markdown: ExportPhase2Copy.markdown
        case .plainText: ExportPhase2Copy.plainText
        case .srt: ExportPhase2Copy.srt
        case .vtt: ExportPhase2Copy.vtt
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
