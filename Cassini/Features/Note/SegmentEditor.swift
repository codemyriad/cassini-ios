import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Edit passage (iOS extra): the passage's text and speaker. Save writes it only while the transcript still holds the
/// passage as it was; otherwise the editor stays open and says "This passage changed while you were editing." While a
/// job runs for the note, the editor is locked: it says why and cannot save.
struct SegmentEditor: View {
    let noteID: UUID
    let segment: TranscriptSegment
    @Environment(LibraryStore.self) private var library
    @Environment(ProcessingStore.self) private var processing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clock) private var clock
    @State private var text: String
    @State private var speaker: String
    @State private var problem: String?
    @State private var saving = false

    init(noteID: UUID, segment: TranscriptSegment) {
        self.noteID = noteID; self.segment = segment
        _text = State(initialValue: segment.text); _speaker = State(initialValue: segment.speakerID ?? "")
    }

    private var note: Note? { library.note(noteID) }
    private var speakers: [NoteSpeaker] { note?.speakers ?? [] }
    /// A job for the note makes the transcript read-only.
    private var locked: Bool { note.flatMap { ReadOnlyReason.of($0, job: processing.state.jobs[noteID]) } != nil }

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
        .tint(.ember)
        .interactiveDismissDisabled(text != segment.text)
    }

    private func save() {
        let original = segment
        let revised = segment.revised(text: text, speakerID: speaker.isEmpty ? nil : speaker, speakers: speakers)
        guard note?.holds(original) == true else {
            problem = NoteCopy.passageChanged
            return
        }
        guard revised != original else { dismiss(); return }
        saving = true
        let stamp = VersionStamp(date: clock.now)
        Task {
            // The change runs again on the stored note when someone else saved it meanwhile; it then finds the passage
            // gone, and the editor says so.
            let saved = await library.commit(noteID) { _ = $0.revisePassage(original, to: revised, stamp: stamp) }
            saving = false
            if saved?.holds(revised) == true { dismiss() } else { problem = NoteCopy.passageChanged }
        }
    }
}
