import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Edit passage (iOS extra): the passage's text and speaker. Save writes it only while the transcript still holds the
/// passage as it was; otherwise the editor stays open and says "This passage changed while you were editing." While a
/// job runs for the note, the editor is locked: it says why and cannot save.
struct SegmentEditor: View {
    let model: NoteScreenModel
    let segment: TranscriptSegment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clock) private var clock
    @State private var text: String
    @State private var speaker: String
    @State private var problem: String?
    @State private var saving = false

    init(model: NoteScreenModel, segment: TranscriptSegment) {
        self.model = model; self.segment = segment
        _text = State(initialValue: segment.text); _speaker = State(initialValue: segment.speakerID ?? "")
    }

    private var speakers: [NoteSpeaker] { model.note?.speakers ?? [] }
    /// A job for the note makes the transcript read-only.
    private var locked: Bool { model.readOnly != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let message = locked ? NoteCopy.passageLocked : problem {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.toneError)
                            .accessibilityIdentifier("passageProblem")
                    }
                }
                Section(NoteCopy.editPassage(at: segment.start)) {
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel(NoteCopy.passageText)
                        .accessibilityIdentifier("passageText")
                }
                Section {
                    Picker(NoteCopy.speaker, selection: $speaker) {
                        Text(NoteCopy.unassigned).tag("")
                        ForEach(Array(speakers.enumerated()), id: \.element.id) { ordinal, speaker in
                            Text(NoteCopy.speakerLabel(speaker.name, id: speaker.id, ordinal: ordinal)).tag(speaker.id)
                        }
                    }
                } header: { Text(NoteCopy.speaker) } footer: { Text(NoteCopy.speakerFooter) }
            }
            .paperListBackground()
            .disabled(locked)
            .navigationTitle(NoteCopy.editPassage).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NoteCopy.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NoteCopy.save) { save() }
                        .disabled(locked || saving || !TranscriptSegment.isSavable(text))
                        .accessibilityIdentifier("savePassage")
                }
            }
        }
        .tint(.accent)
        .interactiveDismissDisabled(text != segment.text)
    }

    private func save() {
        let revised = segment.revised(text: text, speakerID: speaker.isEmpty ? nil : speaker, speakers: speakers)
        saving = true
        let stamp = VersionStamp(date: clock.now)
        Task {
            let outcome = await model.revisePassage(segment, to: revised, stamp: stamp)
            saving = false
            switch outcome {
            case .saved: dismiss()
            case .changed: problem = NoteCopy.passageChanged
            case .locked: break // The editor says why already.
            }
        }
    }
}
