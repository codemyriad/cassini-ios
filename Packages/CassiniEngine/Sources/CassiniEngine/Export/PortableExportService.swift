import Foundation
import CassiniCore
import CassiniNotebook

/// Writes a note as a Cassini document: its audio as Ogg Opus with every transcript version made on this device added
/// as a variant (and, for a source that is not verified, its imported variants too), the note's own transcript last
/// and default.
///
/// The audio is the imported Ogg Opus when the note has one (a verified document keeps its earlier variants), else the
/// playable file encoded to Opus. Intermediate files go in `<folder>/work/`, which is removed afterwards, so no title
/// can collide with them. The source is never changed.
public struct PortableExportService: Sendable {
    private let audio: any AudioProcessing
    private let provenance: any ProvenanceStoring

    /// `provenance` holds the latest on-device run's record, which each variant whose words are the run's carries.
    public init(audio: any AudioProcessing, provenance: any ProvenanceStoring) {
        self.audio = audio
        self.provenance = provenance
    }

    /// The exported file, `<folder>/<filename>.opus`. Nothing it made stays in `folder` when it throws.
    public func export(_ note: Note, original: URL, playable: URL, into folder: URL, filename: String) async throws -> URL {
        let work = folder.appendingPathComponent("work", isDirectory: true)
        let output = folder.appendingPathComponent(filename).appendingPathExtension("opus")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            var opus = original
            if (try? ImportClassifier.sniff(fileAt: original)) != .oggOpus {
                opus = work.appendingPathComponent("encoded.opus")
                try await audio.encodeOpus(playable, to: opus)
            }
            var variants = Self.keptVariants(of: note)
            let run = provenance.load(note.id)
            let audit = Self.attributionAudit(of: note, original: original)
            for (index, version) in Self.versionsToSeal(of: note).enumerated() {
                try Task.checkCancellation()
                var snapshot = note
                snapshot.transcript = version.segments
                snapshot.speakers = version.speakers
                let next = work.appendingPathComponent("version-\(index).opus")
                variants[version.id] = try await Self.seal(snapshot, opus, next, Self.record(version, run, variants, note, audit))
                opus = next
            }
            try Task.checkCancellation()
            var current = note.versions?.first { $0.id == note.selectedVersionID }
                ?? TranscriptVersion(kind: .editedTranscript, segments: note.transcript, speakers: note.speakers ?? [])
            current.segments = note.transcript
            _ = try await Self.seal(note, opus, output, Self.record(current, run, variants, note, audit))
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The versions besides the current one that the export adds as variants, oldest first. A verified source keeps
    /// its own variants, so only the ones made on this device are added; any other source is sealed afresh, so its
    /// readable imported variants are added too.
    static func versionsToSeal(of note: Note) -> [TranscriptVersion] {
        let sourceKeepsVariants = note.document?.state == .ok
        return (note.versions ?? []).filter { version in
            version.id != note.selectedVersionID && !version.segments.isEmpty
                && (version.portableID == nil || !sourceKeepsVariants)
        }
    }

    /// The variant ids of the imported versions a verified source keeps, by version.
    private static func keptVariants(of note: Note) -> [UUID: String] {
        guard note.document?.state == .ok else { return [:] }
        var ids: [UUID: String] = [:]
        for version in note.versions ?? [] { if let portableID = version.portableID { ids[version.id] = portableID } }
        return ids
    }

    /// The provenance record of `version`: the run's while it holds the run's words; for a re-attribution, the
    /// variant its source version became and, when that source is a variant of the verified document, the document's
    /// attribution audit; and its merge, which names the variant its source version became.
    private static func record(_ version: TranscriptVersion, _ run: ProvenanceRecord?, _ variants: [UUID: String],
                               _ note: Note, _ audit: JSONObject?) -> JSONObject {
        let source = version.attributedFrom.flatMap { id in note.versions?.first { $0.id == id } }
        return ExportProvenance.record(run: run?.provenance(for: version.segments), merges: version.speakerMerges,
                                       derivedFrom: version.derivedFrom.flatMap { variants[$0] },
                                       attributedFrom: version.attributedFrom.flatMap { variants[$0] },
                                       sourceAttribution: source?.portableID == nil ? nil : audit)
    }

    /// The verified source document's `provenance.attribution`, which describes its own variants; nil for any other
    /// source, which the export seals afresh, and when no version re-attributes one of its variants. The source was
    /// verified at import, so only its tags are read again.
    private static func attributionAudit(of note: Note, original: URL) -> JSONObject? {
        guard note.document?.state == .ok, let versions = note.versions else { return nil }
        let imported = Set(versions.filter { $0.portableID != nil }.map(\.id))
        guard versions.contains(where: { $0.attributedFrom.map(imported.contains) ?? false }) else { return nil }
        return CassiniDocument.read(original, verify: false).manifest?["provenance"]?.object?["attribution"]?.object
    }

    private static func seal(_ note: Note, _ opus: URL, _ target: URL, _ processing: JSONObject) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            try PortableTranscript.export(note: note, opus: opus, destination: target, processing: processing)
        }.value
    }
}
