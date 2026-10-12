import Foundation
import CassiniCore

/// Verified portable documents preserve all readable transcript variants and speaker identities.
public struct PortableTranscript: Sendable {
    public let title: String
    public let language: String
    public let duration: Double
    public let segments: [TranscriptSegment]
    public let speakers: [NoteSpeaker]
    public let versions: [TranscriptVersion]
    public let selectedVersionID: UUID?

    public static func read(from url: URL) -> PortableTranscript? {
        let document = CassiniDocument.read(url)
        guard document.state == "ok", let selected = document.selected()?.transcript else { return nil }
        var selectedID: UUID?
        let versions = document.variants.compactMap { variant -> TranscriptVersion? in
            guard let transcript = variant.transcript else { return nil }
            let segments = project(transcript, document: document)
            var seen: Set<String> = []
            let speakers = transcript.words.compactMap { word -> NoteSpeaker? in
                guard seen.insert(word.speaker).inserted else { return nil }
                return NoteSpeaker(id: word.speaker, name: document.speakerLabel(word.speaker) ?? word.speaker)
            }
            var version = TranscriptVersion(name: "Imported · \(variant.id)", segments: segments, speakers: speakers)
            version.portableID = variant.id
            if variant.id == document.defaultId { selectedID = version.id }
            return version
        }
        guard let current = versions.first(where: { $0.id == selectedID }) else { return nil }
        let duration = (try? document.manifest?.object("meeting").number("durationMs")) ?? 0
        return PortableTranscript(title: document.title, language: selected.language, duration: Double(duration) / 1000,
                                  segments: current.segments, speakers: current.speakers, versions: versions, selectedVersionID: selectedID)
    }
    private static func project(_ transcript: Transcript, document: CassiniDocument) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []; var group: [Word] = []
        func flush() {
            guard let first = group.first else { return }
            let words = group.enumerated().map { index, word in
                TimedWord(text: word.text + (index == group.count - 1 ? "" : " "), start: Double(word.startMs) / 1000, end: Double(word.endMs) / 1000)
            }
            segments.append(TranscriptSegment(text: group.map(\.text).joined(separator: " "), start: Double(first.startMs) / 1000,
                end: Double(group.map(\.endMs).max() ?? first.endMs) / 1000, speaker: document.speakerLabel(first.speaker) ?? first.speaker,
                speakerID: first.speaker, words: words))
            group.removeAll(keepingCapacity: true)
        }
        for word in transcript.words {
            if let previous = group.last, previous.speaker != word.speaker || group.count >= 45 || word.startMs - previous.endMs > 2000 { flush() }
            group.append(word)
        }
        flush(); return segments
    }
    /// Appends an edited variant to a copy. The source and every earlier portable variant remain intact.
    public static func export(note: Note, opus: URL, destination: URL) throws {
        var existing = CassiniDocument.read(opus)
        let words = note.transcript.flatMap { segment -> [Word] in
            let id = segment.speakerID ?? "unassigned"
            let source = segment.words.isEmpty ? [TimedWord(text: segment.text, start: segment.start, end: segment.end)] : segment.words
            // A source run may contain multiple words. Preserve its actual range for each; never invent subword timing.
            return source.flatMap { word in word.text.split(whereSeparator: \.isWhitespace).map {
                Word(id, Int64((word.start * 1000).rounded()), Int64((word.end * 1000).rounded()), String($0))
            } }
        }
        guard !words.isEmpty else { throw CassiniError("A transcript is required for a Cassini document") }
        let labels = Dictionary((note.speakers ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if existing.state == "ok", var manifest = existing.manifest {
            if var meeting = manifest["meeting"]?.object { meeting["title"] = .string(note.title); manifest["meeting"] = .object(meeting) }
            if let oldSpeakers = manifest["speakers"]?.array {
                manifest["speakers"] = .array(oldSpeakers.map { entry in
                    guard var speaker = entry.object, let id = speaker["id"]?.string, let label = labels[id] else { return entry }
                    speaker["label"] = .string(label); return .object(speaker)
                })
            }
            existing.manifest = manifest
        }
        _ = try CassiniDocument.create(opus, transcript: Transcript(words, language: note.language), title: note.title,
            processing: JSONObject([("engine", .string("cassini-ios")), ("kind", .string("user-edited"))]),
            existing: existing.state == "ok" ? existing : nil, speakerLabels: labels, target: destination)
    }
}
