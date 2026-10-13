import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Document info (Android `DocumentInfoDialog`): the note's facts, then the shown transcript's: language, how and how
/// fast it was transcribed on this device, the model, the speakers and the file size. Read when the sheet opens.
struct DocumentInfoSheet: View {
    let noteID: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var facts: DocumentInfoFacts?

    var body: some View {
        NavigationStack {
            List {
                if let facts {
                    Section {
                        if let trust = facts.trust { row(Self.status, DocumentTrustChip.label(trust)) }
                        row(Self.title, facts.title)
                        row(Self.recorded, facts.createdAt.formatted(
                            Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)))
                        row(Self.duration, TimeText.clock(facts.duration))
                        row(Self.contents, "\(Self.versions(facts.versions)) · \(NoteCopy.speakerCount(facts.speakers))")
                    }
                    Section(Self.selectedVersion) {
                        if let language = facts.language {
                            row(Self.language, locale.localizedString(forIdentifier: language) ?? language)
                        }
                        if let line = transcriptionLine(facts) { row(Self.transcription, line) }
                        if let model = facts.model { row(Self.model, model) }
                        if let line = speakersLine(facts) { row(NoteCopy.speakers, line) }
                        if let bytes = facts.fileBytes { row(Self.fileSize, bytes.formatted(.byteCount(style: .file))) }
                        if let id = facts.meetingID {
                            LabeledContent(Self.meetingID) {
                                Text(verbatim: id).font(.footnote.monospaced()).foregroundStyle(Color.ink)
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                            .accessibilityIdentifier("meetingID")
                        }
                        if let vendor = facts.vendor { row(Self.madeBy, vendor) }
                        if let error = facts.readError { row(Self.readError, error) }
                    }
                }
            }
            .paperListBackground()
            .navigationTitle(NoteCopy.documentInfo).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(NoteCopy.close) { dismiss() } } }
        }
        .task {
            guard let note = library.note(noteID) else { return }
            facts = await Self.read(note, provenance: library.noteStore.map { ProvenanceFiles(notes: $0) },
                                    audio: library.originalAudioURL(note) ?? library.audioURL(note))
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        LabeledContent(key) { Text(value).foregroundStyle(Color.ink).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }

    /// Reads the run's record and the audio file's size off the main actor.
    @concurrent private static func read(_ note: Note, provenance: ProvenanceFiles?, audio: URL?) async -> DocumentInfoFacts {
        let bytes = audio.flatMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        }?.int64Value
        return DocumentInfoFacts.of(note, provenance: provenance?.provenance(for: note), fileBytes: bytes)
    }

    private func transcriptionLine(_ facts: DocumentInfoFacts) -> String? {
        var lines: [String] = []
        if let ms = facts.processingMs, let factor = facts.realtimeFactor {
            let time = RecordingCopy.compact(Double(ms) / 1000)
            let speed = factor >= 10 ? factor.formatted(.number.precision(.fractionLength(0)))
                : factor.formatted(.number.precision(.fractionLength(1)))
            lines.append(String(localized: "Transcribed on this device in \(time) · \(speed)× realtime", table: "Note"))
        }
        if let resumed = facts.resumedFromMs {
            lines.append(String(localized: "Resumed from \(TimeText.clock(Double(resumed) / 1000))", table: "Note"))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func speakersLine(_ facts: DocumentInfoFacts) -> String? {
        var lines: [String] = []
        if let apart = facts.speakersToldApart {
            lines.append(apart ? String(localized: "Speakers told apart on this device", table: "Note")
                         : String(localized: "All words shown as one voice", table: "Note"))
        }
        if facts.namesFromVoices > 0 {
            lines.append(String(localized: "\(facts.namesFromVoices) names from saved voices", table: "Note"))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func versions(_ count: Int) -> String { String(localized: "\(count) versions", table: "Note") }
    private static let status = String(localized: "Status", table: "Note")
    private static let title = String(localized: "Title", table: "Note")
    private static let recorded = String(localized: "Recorded", table: "Note")
    private static let duration = String(localized: "Duration", table: "Note")
    private static let contents = String(localized: "Contents", table: "Note")
    private static let selectedVersion = String(localized: "Selected version", table: "Note")
    private static let language = String(localized: "Language", table: "Note")
    private static let transcription = String(localized: "Transcription", table: "Note")
    private static let model = String(localized: "Model", table: "Note")
    private static let fileSize = String(localized: "File size", table: "Note")
    private static let meetingID = String(localized: "Meeting ID", table: "Note", comment: "Document info: the document's meeting id")
    private static let madeBy = String(localized: "Made by", table: "Note", comment: "Document info: the app that wrote an imported document")
    private static let readError = String(localized: "Read error", table: "Note")
}
