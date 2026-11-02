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
    /// The language of the selected transcript as stored (`TranscriptLanguage`); empty when there is none.
    public let language: String
    public let versions: [TranscriptVersion]
    public let selectedVersionID: UUID?
    /// Transcript variants that could not be read, by variant id, with the reason.
    public let unavailableVariants: [String: String]
    /// The OpusTags vendor string of the app that wrote the file.
    public let vendor: String?
    /// `meeting.id`.
    public let meetingID: String?

    public var selected: TranscriptVersion? { versions.first { $0.id == selectedVersionID } }
    public var hasTranscript: Bool { selected != nil }
    public var segments: [TranscriptSegment] { selected?.segments ?? [] }
    public var speakers: [NoteSpeaker] { selected?.speakers ?? [] }

    /// What the note stores about the document.
    public var info: DocumentInfo {
        DocumentInfo(state: state, warnings: warnings, unavailableVariants: unavailableVariants, vendor: vendor,
                     meetingID: meetingID)
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
        meetingID = meeting?["id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
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
                var version = TranscriptVersion(kind: .imported, segments: Self.segments(transcript, document),
                                                speakers: Self.speakers(transcript, document), language: transcript.language)
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

    /// Words grouped into segments (`TranscriptSegment.segments(of:label:)`), named by the manifest's labels.
    private static func segments(_ transcript: Transcript, _ document: CassiniDocument) -> [TranscriptSegment] {
        TranscriptSegment.segments(of: transcript.words) { document.speakerLabel($0) }
    }
}

public enum PortableExportError: Error, Equatable, Sendable {
    /// The note has no words to put in a document.
    case noTranscript
    /// The words do not fit in one transcript body, or beside what the file already carries.
    case tooLong
}

extension PortableTranscript {
    /// The states of a source whose transcripts a reader shows but its audio does not vouch for: an export never
    /// seals their variants as verified.
    public static let untrustedStates: Set<DocumentState> = [.unverified, .staleAudio]

    /// Writes `opus` to `destination` with the note's transcript added as the new default variant. A verified source
    /// keeps every earlier variant and gets the note's title and speaker names. Any other source is sealed afresh over
    /// the same audio: it keeps its foreign tags and, from an unverified or stale manifest, its private `x` data,
    /// unknown members, meeting id and meeting details verbatim (`CassiniDocument.seal`), but none of its variants.
    /// The variant's language is the note's as it is (`TranscriptLanguage`): the run's, or an imported variant's value as
    /// stored. `processing` is the variant's provenance record (`ExportProvenance`). `source` is the document at `opus` when the
    /// caller has read (and verified) it already. Returns the new variant's id. The source is never changed.
    ///
    /// Passages without a speaker are the speaker `unassigned` (`ExportTranscript.unassignedSpeaker`). When a word uses
    /// it and the manifest has no entry for it yet, its entry is labelled `unassignedLabel`, the label the app shows
    /// such passages under in the user's language (D47: written when produced, shown as stored). An entry a verified
    /// source already has keeps its stored label, unless the note names a speaker `unassigned` (one read from that
    /// entry, perhaps renamed), whose name it gets as any other speaker's.
    @discardableResult
    public static func export(note: Note, opus: URL, destination: URL, unassignedLabel: String,
                              processing: JSONObject = ExportProvenance.userEdited,
                              source known: CassiniDocument? = nil) throws -> String? {
        let source = known ?? CassiniDocument.read(opus)
        let transcript = Transcript(words(of: note), language: note.language)
        guard !transcript.words.isEmpty else { throw PortableExportError.noTranscript }
        guard WordBodyBudget.fits(transcript.words, language: transcript.language) else { throw PortableExportError.tooLong }
        let labels = Dictionary((note.speakers ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var existing: CassiniDocument?
        var carried: CassiniDocument?
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
        } else if untrustedStates.contains(source.state) {
            carried = source
        }
        let fits = try existing.map { try WordBodyBudget.fitsHeader(transcript, beside: $0) }
            ?? WordBodyBudget.fitsHeader(transcript, sealing: FileSource(opus), carrying: carried)
        guard fits else { throw PortableExportError.tooLong }
        // Only a new entry takes it: the seal labels the speakers the manifest does not have yet.
        var newLabels = labels
        if newLabels[ExportTranscript.unassignedSpeaker] == nil { newLabels[ExportTranscript.unassignedSpeaker] = unassignedLabel }
        return try CassiniDocument.create(opus, transcript: transcript, title: note.title, processing: processing,
                                          existing: existing, speakerLabels: newLabels, carrying: carried,
                                          target: destination).defaultId
    }

    /// The note's words; a passage without word timing becomes words that each span the whole passage, and one
    /// without a speaker is `ExportTranscript.unassignedSpeaker`'s.
    static func words(of note: Note) -> [Word] {
        note.transcript.flatMap { segment -> [Word] in
            let id = segment.speakerID ?? ExportTranscript.unassignedSpeaker
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

extension Note {
    /// Whether the note shows its selected version as it was read from the imported document.
    public var showsImportedVersion: Bool {
        shownVersionIndex.map { versions?[$0].portableID != nil } ?? false
    }

    /// Whether the note holds nothing made on this device beside its imported document: it shows an imported version
    /// as it was read, and every version with words is a variant of the document. An export of such a note from a
    /// document it does not trust is that document byte for byte, as Android's Save a copy is.
    public var holdsOnlyImportedVersions: Bool {
        showsImportedVersion && (versions ?? []).allSatisfy { $0.segments.isEmpty || $0.portableID != nil }
    }
}
