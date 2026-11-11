import Foundation
import CassiniCore
import CassiniNotebook

/// Writes a note as a Cassini document: its audio as Ogg Opus with every transcript version made on this device added
/// as a variant, the note's own transcript last and default. Each variant carries its own version's language: the
/// run's that made its words, or an imported variant's as stored (`TranscriptLanguage`).
///
/// The audio is the imported Ogg Opus when the note has one, else the playable file encoded to Opus. What the export
/// keeps of an imported document depends on how that document reads now, verified once per export:
/// - `ok`: every variant stays, with the note's title and speaker names.
/// - `unverified` or `staleAudio`, with nothing made on this device (`Note.holdsOnlyImportedVersions`): the export is
///   the document itself, byte for byte, as Android's Save a copy is. Its variants, provenance, private data and
///   honest state all survive.
/// - `unverified` or `staleAudio` with versions made here: a fresh seal of only those versions over the same audio,
///   carrying the source manifest's private `x` data, unknown members and meeting verbatim. The imported variants
///   are not sealed again, since the audio does not vouch for them; the note still shows them.
/// - anything else: a fresh seal that keeps only the foreign tags.
///
/// Intermediate files go in `<folder>/work/`, which is removed afterwards, so no title can collide with them. The
/// source is never changed.
public struct PortableExportService: Sendable {
    private let audio: any AudioProcessing
    private let provenance: any ProvenanceStoring
    private let unassignedLabel: String

    /// `provenance` holds the note's on-device runs' records; each variant whose words a run made carries that run's.
    /// `unassignedLabel` is what the app calls a passage without a speaker, in the user's language: the label of the
    /// `unassigned` speaker each variant that has such passages adds (`PortableTranscript.export`).
    public init(audio: any AudioProcessing, provenance: any ProvenanceStoring, unassignedLabel: String) {
        self.audio = audio
        self.provenance = provenance
        self.unassignedLabel = unassignedLabel
    }

    /// D96 backup: clean imported documents and raw/opaque audio keep their exact bytes, so re-import deduplicates.
    /// Local transcript/title/speaker changes still need a complete portable snapshot; the source is never written.
    public func archiveSnapshot(_ note: Note, original: URL, playable: URL, into folder: URL) async throws -> URL {
        var originalBytes = ArchiveContents.preservesOriginal(note)
        if !originalBytes, note.document != nil {
            let document = try await CancellableFileWork.run { PortableTranscript.read(from: original) }
            if let document { originalBytes = ArchiveContents.matchesImportedDocument(note, document) }
        }
        if originalBytes {
            let ext = original.pathExtension
            return try await BulkExportService.copyOriginal(original, to: folder.appendingPathComponent("original" + (ext.isEmpty ? "" : "." + ext)))
        }
        return try await export(note, original: original, playable: playable, into: folder, filename: "document")
    }

    /// The exported file, `<folder>/<filename>.opus`. Nothing it made stays in `folder` when it throws.
    public func export(_ note: Note, original: URL, playable: URL, into folder: URL, filename: String) async throws -> URL {
        let work = folder.appendingPathComponent("work", isDirectory: true)
        let output = folder.appendingPathComponent(filename).appendingPathExtension("opus")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            var opus = original
            var source: CassiniDocument?
            if (try? ImportClassifier.sniff(fileAt: original)) == .oggOpus {
                source = try await Self.read(original)
            } else {
                opus = work.appendingPathComponent("encoded.opus")
                try await audio.encodeOpus(playable, to: opus)
            }
            let state = source?.state
            if let state, PortableTranscript.untrustedStates.contains(state), note.holdsOnlyImportedVersions {
                try Task.checkCancellation()
                _ = try await BulkExportService.copyOriginal(original, to: output)
                return output
            }
            let verified = state == .ok
            var variants = verified ? Self.keptVariants(of: note) : [:]
            let runs = provenance.records(note.id)
            let audit = verified ? try await Self.attributionAudit(of: note, original: original) : nil
            var versions = Self.versionsToSeal(of: note)
            var current = note.versions?.first { $0.id == note.selectedVersionID }
                ?? TranscriptVersion(kind: .editedTranscript, segments: note.transcript, speakers: note.speakers ?? [])
            current.segments = note.transcript
            current.speakers = note.speakers ?? []
            current.language = note.language
            // An imported version is sealed again only over audio that vouches for it; otherwise the newest version
            // made here is the default.
            if current.segments.isEmpty || (!verified && note.showsImportedVersion), let last = versions.popLast() { current = last }
            for (index, version) in versions.enumerated() {
                try Task.checkCancellation()
                let next = work.appendingPathComponent("version-\(index).opus")
                variants[version.id] = try await seal(Self.showing(version, of: note), opus, next,
                                                      Self.record(version, runs, variants, note, audit), source)
                // Each successor contains every preceding variant. Keeping old complete-audio copies would
                // multiply scratch space by the version count for one note.
                if opus != original { try FileManager.default.removeItem(at: opus) }
                opus = next
                source = nil
            }
            try Task.checkCancellation()
            _ = try await seal(Self.showing(current, of: note), opus, output,
                               Self.record(current, runs, variants, note, audit), source)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The versions besides the current one that the export adds as variants, oldest first: the ones with words made
    /// on this device. An imported version is either kept by its verified source or not sealed again.
    static func versionsToSeal(of note: Note) -> [TranscriptVersion] {
        (note.versions ?? []).filter { version in
            version.id != note.selectedVersionID && !version.segments.isEmpty && version.portableID == nil
        }
    }

    /// `note` showing `version`'s transcript and speakers, in the version's language.
    private static func showing(_ version: TranscriptVersion, of note: Note) -> Note {
        var snapshot = note
        snapshot.transcript = version.segments
        snapshot.speakers = version.speakers
        snapshot.language = version.language
        return snapshot
    }

    /// The variant ids of the imported versions a verified source keeps, by version.
    private static func keptVariants(of note: Note) -> [UUID: String] {
        var ids: [UUID: String] = [:]
        for version in note.versions ?? [] { if let portableID = version.portableID { ids[version.id] = portableID } }
        return ids
    }

    /// The provenance record of `version`: the newest run's of `runs` that made its words, with that run's language; for
    /// a re-attribution, the
    /// variant its source version became and, when that source is a variant of the verified document, the document's
    /// attribution audit; and its merge, which names the variant its source version became.
    private static func record(_ version: TranscriptVersion, _ runs: [ProvenanceRecord], _ variants: [UUID: String],
                               _ note: Note, _ audit: JSONObject?) -> JSONObject {
        let source = version.attributedFrom.flatMap { id in note.versions?.first { $0.id == id } }
        let run = ProvenanceRecord.newest(describing: version.segments, in: runs)?.provenance(for: version.segments)
        return ExportProvenance.record(run: run, merges: version.speakerMerges,
                                       derivedFrom: version.derivedFrom.flatMap { variants[$0] },
                                       attributedFrom: version.attributedFrom.flatMap { variants[$0] },
                                       sourceAttribution: source?.portableID == nil ? nil : audit)
    }

    /// The verified source document's `provenance.attribution`, which describes its own variants; nil when no version
    /// re-attributes one of its variants. The source was verified already, so only its tags are read again.
    private static func attributionAudit(of note: Note, original: URL) async throws -> JSONObject? {
        guard let versions = note.versions else { return nil }
        let imported = Set(versions.filter { $0.portableID != nil }.map(\.id))
        guard versions.contains(where: { $0.attributedFrom.map(imported.contains) ?? false }) else { return nil }
        return try await CancellableFileWork.run {
            CassiniDocument.read(original, verify: false).manifest?["provenance"]?.object?["attribution"]?.object
        }
    }

    /// Seals `note` into `target`; `source` is the document at `opus` when it has been read already.
    private func seal(_ note: Note, _ opus: URL, _ target: URL, _ processing: JSONObject,
                      _ source: CassiniDocument?) async throws -> String? {
        let unassignedLabel = unassignedLabel
        return try await CancellableFileWork.run {
            try PortableTranscript.export(note: note, opus: opus, destination: target, unassignedLabel: unassignedLabel,
                                          processing: processing, source: source)
        }
    }

    /// The document at `url`, its audio verified.
    private static func read(_ url: URL) async throws -> CassiniDocument {
        try await CancellableFileWork.run { CassiniDocument.read(url) }
    }
}
