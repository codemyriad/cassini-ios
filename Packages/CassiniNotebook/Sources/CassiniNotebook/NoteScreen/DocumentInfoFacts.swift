import Foundation

/// The Document info sheet (Android `InfoUi`): the note's facts, then the shown transcript's. Nil values hide their row.
public struct DocumentInfoFacts: Hashable, Sendable {
    public var trust: DocumentTrust?
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var versions: Int
    public var speakers: Int
    /// BCP-47; nil when no language was chosen.
    public var language: String?
    /// "Transcribed on this device in 2 min · 11× realtime": the analyzer's time and the audio over it.
    public var processingMs: Int64?
    public var realtimeFactor: Double?
    public var model: String?
    /// Speakers told apart on this device, or all words shown as one voice; nil without a record of the run.
    public var speakersToldApart: Bool?
    /// Speakers the run named automatically from a saved voice (`x-speakerIdentification.autoApplied`, as Android
    /// reads it); 0 without that record.
    public var namesFromVoices: Int
    public var resumedFromMs: Int64?
    public var fileBytes: Int64?
    /// The imported document's meeting id (`meeting.id`), after the file size as on Android.
    public var meetingID: String?
    /// The app that wrote an imported document.
    public var vendor: String?
    /// Why a damaged document's transcript could not be read.
    public var readError: String?

    /// The facts of `note`, with the record of the run that made its transcript (nil when it is not the run's) and
    /// the size of its audio file.
    public static func of(_ note: Note, provenance: TranscriptProvenance?, fileBytes: Int64?) -> DocumentInfoFacts {
        let speakers = Set(note.transcript.compactMap(\.speakerID))
        let processing = provenance.flatMap { $0.inferenceMs > 0 ? $0.inferenceMs : nil }
        let readError: String? = switch note.document?.state {
        case .unreadable?, .invalidMetadata?:
            note.document.flatMap { info in info.warnings.isEmpty ? nil : info.warnings.joined(separator: "\n") }
        default: nil
        }
        return DocumentInfoFacts(
            trust: DocumentTrust.of(note), title: note.title, createdAt: note.createdAt, duration: note.duration,
            versions: note.versionCount, speakers: speakers.count,
            language: (provenance?.language).flatMap { $0.isEmpty ? nil : $0 } ?? (note.language.isEmpty ? nil : note.language),
            processingMs: processing,
            realtimeFactor: processing.map { note.duration * 1000 / Double($0) },
            model: provenance.map { modelName($0.engine) },
            speakersToldApart: provenance.map { $0.speakerDiarization != nil },
            namesFromVoices: provenance?.speakerIdentification?.autoApplied ?? 0,
            resumedFromMs: provenance.flatMap { $0.resumedFromMs > 0 ? $0.resumedFromMs : nil },
            fileBytes: fileBytes, meetingID: note.document?.meetingID, vendor: note.document?.vendor, readError: readError)
    }

    /// The name Document info shows for a provenance engine id: Apple's on-device speech model for this app's engine,
    /// and the id as it is for an engine this app does not know.
    public static func modelName(_ engine: String) -> String {
        engine == TranscriptProvenance.appleSpeech ? appleSpeechName : engine
    }

    public static let appleSpeechName = "Apple SpeechTranscriber"
}
