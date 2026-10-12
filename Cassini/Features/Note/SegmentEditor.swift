import SwiftUI
import CassiniNotebook

struct SegmentEditor: View {
    let segment: TranscriptSegment
    let speakers: [NoteSpeaker]
    let save: (TranscriptSegment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var speaker: String

    init(segment: TranscriptSegment, speakers: [NoteSpeaker], save: @escaping (TranscriptSegment) -> Void) {
        self.segment = segment; self.speakers = speakers; self.save = save
        _text = State(initialValue: segment.text); _speaker = State(initialValue: segment.speakerID ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Passage at \(TimeText.clock(segment.start))") { TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("Passage text") }
                Section {
                    Picker("Speaker", selection: $speaker) { Text("Unassigned").tag(""); ForEach(speakers) { Text($0.name).tag($0.id) } }
                } header: { Text("Speaker") } footer: { Text("Assign this passage to a speaker. Rename or merge people from Speakers.") }
            }.navigationTitle("Edit passage").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(revised); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.tint(.ember)
    }

    private var revised: TranscriptSegment {
        var revised = segment
        revised.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if revised.text != segment.text { revised.words = [] }
        revised.speakerID = speaker.isEmpty ? nil : speaker
        revised.speaker = speakers.first { $0.id == speaker }?.name
        return revised
    }
}
