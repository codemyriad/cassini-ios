import Foundation

/// One recording or import with everything shown about it. Stored as `note.json`, schema 2; schema 1 files decode and
/// are written back as schema 2 on their next save.
public struct Note: Identifiable, Hashable, Sendable {
    public static let schemaVersion = 2

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var audioFilename: String
    public var duration: Double = 0
    public var status: NoteStatus = .audioOnly
    public var transcript: [TranscriptSegment] = []
    public var bookmarks: [Bookmark] = []
    public var waveform: [Float] = []
    public var isFavorite = false
    public var trashedAt: Date?
    public var playbackPosition: Double = 0
    /// BCP-47 (`en-US`), or empty when no language was chosen.
    public var language = ""
    public var audio: AudioState = .plain
    public var origin: NoteOrigin = .recorded
    public var document: DocumentInfo?
    public var sourceSha256: String?
    public var trashedJob: TrashedJob?
    /// The Library preview, cached at the last playback position.
    public var previewText: String?
    public var failure: JobFailure?
    public var speakerAnalysisFailure: JobFailure?
    public var originalAudioFilename: String?
    public var speakers: [NoteSpeaker]?
    public var versions: [TranscriptVersion]?
    public var selectedVersionID: UUID?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), audioFilename: String = "audio.m4a") {
        self.id = id; self.title = title; self.createdAt = createdAt; self.audioFilename = audioFilename
    }

    public var text: String { transcript.map(\.text).joined(separator: " ") }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    public var isRecording: Bool { audio == .live }
}

public enum NoteDecodingError: Error, Equatable {
    case unsupportedSchema(Int)
}

extension Note: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, audioFilename, duration, status, transcript, bookmarks, waveform
        case isFavorite, trashedAt, playbackPosition, language, audio, origin, document, sourceSha256, trashedJob
        case previewText, failure, speakerAnalysisFailure, originalAudioFilename, speakers, versions, selectedVersionID
        // Schema 1 only.
        case failureMessage, playbackUnavailable, speakerAnalysisMessage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(schema) else { throw NoteDecodingError.unsupportedSchema(schema) }
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        audioFilename = try c.decode(String.self, forKey: .audioFilename)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        status = (try? c.decodeIfPresent(NoteStatus.self, forKey: .status)) ?? .audioOnly
        transcript = try c.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        waveform = try c.decodeIfPresent([Float].self, forKey: .waveform) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        playbackPosition = try c.decodeIfPresent(Double.self, forKey: .playbackPosition) ?? 0
        language = Self.bcp47(try c.decodeIfPresent(String.self, forKey: .language) ?? "")
        originalAudioFilename = try c.decodeIfPresent(String.self, forKey: .originalAudioFilename)
        speakers = try c.decodeIfPresent([NoteSpeaker].self, forKey: .speakers)
        versions = try c.decodeIfPresent([TranscriptVersion].self, forKey: .versions)
        selectedVersionID = try c.decodeIfPresent(UUID.self, forKey: .selectedVersionID)
        document = try c.decodeIfPresent(DocumentInfo.self, forKey: .document)
        sourceSha256 = try c.decodeIfPresent(String.self, forKey: .sourceSha256)
        trashedJob = try c.decodeIfPresent(TrashedJob.self, forKey: .trashedJob)
        previewText = try c.decodeIfPresent(String.self, forKey: .previewText)
        if schema == 1 {
            try decodeSchemaOne(c)
        } else {
            audio = try c.decode(AudioState.self, forKey: .audio)
            origin = try c.decode(NoteOrigin.self, forKey: .origin)
            failure = try c.decodeIfPresent(JobFailure.self, forKey: .failure)
            speakerAnalysisFailure = try c.decodeIfPresent(JobFailure.self, forKey: .speakerAnalysisFailure)
        }
    }

    private mutating func decodeSchemaOne(_ c: KeyedDecodingContainer<CodingKeys>) throws {
        if try c.decodeIfPresent(String.self, forKey: .playbackUnavailable) != nil {
            audio = .unplayable(.unsupportedFormat)
        } else {
            audio = status == .recording ? .live : .plain
        }
        if versions?.contains(where: { $0.portableID != nil }) == true {
            origin = .importedDocument
        } else if originalAudioFilename != nil {
            origin = .imported
        }
        failure = try c.decodeIfPresent(String.self, forKey: .failureMessage).map(Self.legacyFailure)
        speakerAnalysisFailure = try c.decodeIfPresent(String.self, forKey: .speakerAnalysisMessage)
            .map { $0.hasPrefix("No speakers were detected") ? .empty : .speakers }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(audioFilename, forKey: .audioFilename)
        try c.encode(duration, forKey: .duration)
        try c.encode(status, forKey: .status)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(bookmarks, forKey: .bookmarks)
        try c.encode(waveform, forKey: .waveform)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encodeIfPresent(trashedAt, forKey: .trashedAt)
        try c.encode(playbackPosition, forKey: .playbackPosition)
        try c.encode(language, forKey: .language)
        try c.encode(audio, forKey: .audio)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(document, forKey: .document)
        try c.encodeIfPresent(sourceSha256, forKey: .sourceSha256)
        try c.encodeIfPresent(trashedJob, forKey: .trashedJob)
        try c.encodeIfPresent(previewText, forKey: .previewText)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(speakerAnalysisFailure, forKey: .speakerAnalysisFailure)
        try c.encodeIfPresent(originalAudioFilename, forKey: .originalAudioFilename)
        try c.encodeIfPresent(speakers, forKey: .speakers)
        try c.encodeIfPresent(versions, forKey: .versions)
        try c.encodeIfPresent(selectedVersionID, forKey: .selectedVersionID)
    }

    /// Schema 1 stored `Locale.identifier` (`en_US`); schema 2 stores BCP-47 (`en-US`).
    static func bcp47(_ identifier: String) -> String {
        identifier.isEmpty ? "" : Locale(identifier: identifier).identifier(.bcp47)
    }

    /// Schema 1 stored the failure as English text; the messages Cassini wrote map to their codes.
    static func legacyFailure(_ message: String) -> JobFailure {
        if message.hasPrefix("Transcription was interrupted") || message.hasPrefix("Transcription paused when iOS") { return .interrupted }
        if message.hasPrefix("This recording was interrupted") { return .audio }
        return .unknown
    }
}
