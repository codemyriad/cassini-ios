import Foundation
import CassiniCore

/// What a note keeps of a Cassini document: its trust state, and every transcript variant it could read as a version
/// with the speakers' labels.
///
/// SPEC.md asks a reader to show the transcript of an `unverified` or `stale-audio` file (with its warning) as well
/// as an `ok` one; `unreadable`, `invalid-cassini-metadata` and `unknown-cassini-format` give a document with no
/// transcript. A variant that does not decode never hides the others: the first readable one stands in for an
/// unavailable default, and the unavailable ones are kept with their errors.
public struct PortableTranscript: Hashable, Sendable {
    /// The states whose transcripts a reader shows.
    public static let readableStates: Set<DocumentState> = [.ok, .unverified, .staleAudio]

    public let state: DocumentState
    public let warnings: [String]
    /// `meeting.title`; empty when the manifest has none.
    public let title: String
    /// `meeting.createdAtUtc`.
    public let createdAt: Date?
    /// `meeting.durationMs`, in seconds.
    public let duration: TimeInterval?
    /// The language of the selected transcript; empty when there is none.
    public let language: String
    public let versions: [TranscriptVersion]
    public let selectedVersionID: UUID?
    /// Transcript variants that could not be read, by variant id, with the reason.
    public let unavailableVariants: [String: String]
    /// The OpusTags vendor string of the app that wrote the file.
    public let vendor: String?

    public var selected: TranscriptVersion? { versions.first { $0.id == selectedVersionID } }
    public var hasTranscript: Bool { selected != nil }
    public var segments: [TranscriptSegment] { selected?.segments ?? [] }
    public var speakers: [NoteSpeaker] { selected?.speakers ?? [] }

    /// What the note stores about the document.
    public var info: DocumentInfo {
        DocumentInfo(state: state, warnings: warnings, unavailableVariants: unavailableVariants, vendor: vendor)
    }

    /// Reads, and verifies, the document at `url`; nil when it is plain audio (no `CASSINI_FORMAT`).
    public static func read(from url: URL) -> PortableTranscript? {
        let document = CassiniDocument.readChecked(url)
        guard document.state != .plainAudio else { return nil }
        return PortableTranscript(document, vendor: vendor(of: url))
    }

    /// The note's view of `document`; nil for plain audio.
    public init?(_ document: CassiniDocument, vendor: String? = nil) {
        guard document.state != .plainAudio else { return nil }
        state = document.state
        warnings = document.warnings
        self.vendor = vendor
        let meeting = document.manifest?["meeting"]?.object
        title = document.title
        createdAt = meeting?["createdAtUtc"]?.string.flatMap(Self.instant)
        duration = (try? meeting?.number("durationMs")).map { Double($0) / 1000 }
        var unavailable: [String: String] = [:]
        var versions: [TranscriptVersion] = []
        var selectedID: UUID?
        var language = ""
        if Self.readableStates.contains(document.state) {
            let defaultID = document.defaultId
            for variant in document.variants {
                guard let transcript = variant.transcript else {
                    unavailable[variant.id] = variant.error ?? "unavailable"
                    continue
                }
                var version = TranscriptVersion(name: "Imported · \(variant.id)", segments: Self.segments(transcript, document),
                                                speakers: Self.speakers(transcript, document))
                version.portableID = variant.id
                versions.append(version)
                // The default when it decodes, else the first variant that does.
                if variant.id == defaultID || selectedID == nil {
                    selectedID = version.id
                    language = transcript.language
                }
            }
        }
        self.versions = versions
        selectedVersionID = selectedID
        self.language = language
        unavailableVariants = unavailable
    }

    /// The OpusTags vendor string of the file; nil when its headers cannot be read.
    public static func vendor(of url: URL) -> String? {
        guard let tags = try? OggOpus.headers(FileSource(url)).tags, tags.count >= 12 else { return nil }
        let length = Int(UInt32(bitPattern: OggOpus.u32(tags, 8)))
        guard length <= tags.count - 12 else { return nil }
        return String(validating: tags[12..<12 + length], as: UTF8.self)
    }

    private static func instant(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    /// Speakers in order of first appearance, named by the manifest's labels.
    private static func speakers(_ transcript: Transcript, _ document: CassiniDocument) -> [NoteSpeaker] {
        var seen: Set<String> = []
        return transcript.words.compactMap { word in
            guard seen.insert(word.speaker).inserted else { return nil }
            return NoteSpeaker(id: word.speaker, name: document.speakerLabel(word.speaker) ?? word.speaker)
        }
    }

    /// Words grouped into segments: a new one at a change of speaker, a pause over 2 s, or after 45 words.
    private static func segments(_ transcript: Transcript, _ document: CassiniDocument) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var group: [Word] = []
        func flush() {
            guard let first = group.first else { return }
            let words = group.enumerated().map { index, word in
                TimedWord(text: word.text + (index == group.count - 1 ? "" : " "),
                          start: Double(word.startMs) / 1000, end: Double(word.endMs) / 1000)
            }
            segments.append(TranscriptSegment(
                text: group.map(\.text).joined(separator: " "), start: Double(first.startMs) / 1000,
                end: Double(group.map(\.endMs).max() ?? first.endMs) / 1000,
                speaker: document.speakerLabel(first.speaker) ?? first.speaker, speakerID: first.speaker, words: words))
            group.removeAll(keepingCapacity: true)
        }
        for word in transcript.words {
            if let previous = group.last,
               previous.speaker != word.speaker || group.count >= 45 || word.startMs - previous.endMs > 2000 { flush() }
            group.append(word)
        }
        flush()
        return segments
    }
}

public enum PortableExportError: Error, Equatable, Sendable {
    /// The note has no words to put in a document.
    case noTranscript
    /// The words do not fit in one transcript body, or beside what the file already carries.
    case tooLong
}

extension PortableTranscript {
    /// Writes `opus` to `destination` with the note's transcript added as the new default variant. A verified source
    /// keeps every earlier variant and gets the note's title and speaker names; any other source is sealed afresh,
    /// keeping only its foreign tags. `processing` is the variant's provenance record (`ExportProvenance`). Returns the
    /// new variant's id. The source is never changed.
    @discardableResult
    public static func export(note: Note, opus: URL, destination: URL,
                              processing: JSONObject = ExportProvenance.userEdited) throws -> String? {
        let source = CassiniDocument.read(opus)
        let transcript = Transcript(words(of: note), language: Note.bcp47(note.language))
        guard !transcript.words.isEmpty else { throw PortableExportError.noTranscript }
        guard WordBodyBudget.fits(transcript.words, language: transcript.language) else { throw PortableExportError.tooLong }
        let labels = Dictionary((note.speakers ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var existing: CassiniDocument?
        if source.state == .ok, var manifest = source.manifest {
            if var meeting = manifest["meeting"]?.object {
                meeting["title"] = .string(note.title)
                manifest["meeting"] = .object(meeting)
            }
            if let speakers = manifest["speakers"]?.array {
                manifest["speakers"] = .array(speakers.map { entry in
                    guard var speaker = entry.object, let id = speaker["id"]?.string, let label = labels[id] else { return entry }
                    speaker["label"] = .string(label)
                    return .object(speaker)
                })
            }
            var updated = source
            updated.manifest = manifest
            existing = updated
        }
        let fits = try existing.map { try WordBodyBudget.fitsHeader(transcript, beside: $0) }
            ?? WordBodyBudget.fitsHeader(transcript, sealing: FileSource(opus))
        guard fits else { throw PortableExportError.tooLong }
        return try CassiniDocument.create(opus, transcript: transcript, title: note.title, processing: processing,
                                          existing: existing, speakerLabels: labels, target: destination).defaultId
    }

    /// The note's words; a passage without word timing becomes words that each span the whole passage.
    static func words(of note: Note) -> [Word] {
        note.transcript.flatMap { segment -> [Word] in
            let id = segment.speakerID ?? "unassigned"
            let source = segment.words.isEmpty ? [TimedWord(text: segment.text, start: segment.start, end: segment.end)] : segment.words
            // A source run may contain several words. Each keeps the run's range; never invent subword timing.
            return source.flatMap { word in
                word.text.split(whereSeparator: \.isWhitespace).map {
                    Word(id, Int64((word.start * 1000).rounded()), Int64((word.end * 1000).rounded()), String($0))
                }
            }
        }
    }
}
