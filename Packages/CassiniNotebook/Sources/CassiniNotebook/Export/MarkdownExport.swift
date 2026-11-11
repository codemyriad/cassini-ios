import CassiniCore
import Foundation

public struct MarkdownCopy: Sendable {
    public var speakersLine: String
    public var transcriptHeading: String
    public var notesHeading: String
    public var overLine: String
    public var speakerList: @Sendable ([String]) -> String

    public init(speakersLine: String, transcriptHeading: String, notesHeading: String, overLine: String,
                speakerList: @escaping @Sendable ([String]) -> String) {
        self.speakersLine = speakersLine; self.transcriptHeading = transcriptHeading
        self.notesHeading = notesHeading; self.overLine = overLine; self.speakerList = speakerList
    }
}

public struct MarkdownNote: Hashable, Sendable {
    public var atMs: Int64
    public var text: String
    public init(atMs: Int64, text: String) { self.atMs = atMs; self.text = text }
}

/// Copy and formatting captured at export time, independently from the stored content (D47/D50.3).
public struct MarkdownOptions: Sendable {
    public var copy: MarkdownCopy
    public var dateLine: @Sendable (Date, Int64) -> String
    public var untitled: String
    public var unnamedSpeaker: @Sendable (Int) -> String

    public init(copy: MarkdownCopy, dateLine: @escaping @Sendable (Date, Int64) -> String, untitled: String,
                unnamedSpeaker: @escaping @Sendable (Int) -> String) {
        self.copy = copy; self.dateLine = dateLine; self.untitled = untitled; self.unnamedSpeaker = unnamedSpeaker
    }
}

/// S-5 layout with the same D84 paragraphs/chips as Android and the note. UTF-8/LF, one final newline.
public enum MarkdownExport {
    public struct OptionsRequired: Error {}

    public static func write(_ transcript: ExportTranscript, dateLine: String, copy: MarkdownCopy,
                             notes: [MarkdownNote] = []) -> String {
        let rows = TurnModel.rows(of: transcript.words.map {
            TurnModel.Word(speaker: $0.speaker, startMs: Double($0.startMs), endMs: Double($0.endMs),
                           text: $0.text, lowConfidenceSpeaker: $0.lowConfidenceSpeaker)
        }, endsBoundedByAudio: transcript.endsBoundedByAudio)
        var blocks = ["# " + escape(transcript.title)]
        if !dateLine.isEmpty { blocks.append(dateLine) }
        // Inventory includes chip-only speakers; sorting does not change canonical word indices.
        var seen = Set<String>()
        let speakers = transcript.words.enumerated().sorted {
            $0.element.startMs == $1.element.startMs ? $0.offset < $1.offset : $0.element.startMs < $1.element.startMs
        }.compactMap { seen.insert($0.element.speaker).inserted ? $0.element.speaker : nil }
        if !speakers.isEmpty {
            blocks.append(copy.speakersLine.replacingOccurrences(of: "{names}",
                with: speakers.map { escape(transcript.label($0)) }.joined(separator: ", ")))
        }
        blocks.append("## " + copy.transcriptHeading)
        for row in rows {
            let speaker = row.speaker ?? ExportTranscript.unassignedSpeaker
            let prefix = row.continuation ? "" : "**" + escape(transcript.label(speaker)) + "** · "
            var overNames = Set<Data>()
            let over = row.over.map(transcript.label).filter { overNames.insert(Data($0.utf8)).inserted }
            let suffix = over.isEmpty ? "" : " " + escape(copy.overLine.replacingOccurrences(of: "{names}",
                                                                                          with: copy.speakerList(over)))
            let text = TranscriptTurns.text(of: row.members) { transcript.label($0 ?? ExportTranscript.unassignedSpeaker) }
            blocks.append(prefix + clock(Int64(row.startMs.rounded())) + suffix + "\n" + escape(text))
        }
        if !notes.isEmpty {
            blocks.append("## " + copy.notesHeading)
            blocks.append(notes.enumerated().sorted {
                $0.element.atMs == $1.element.atMs ? $0.offset < $1.offset : $0.element.atMs < $1.element.atMs
            }.map { "- " + clock($0.element.atMs) + " " + escape($0.element.text) }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    public static func escape(_ text: String) -> String {
        let normalized = text.unicodeScalars.split(whereSeparator: isWhitespace).map(String.init).joined(separator: " ")
        var escaped = ""
        for scalar in normalized.unicodeScalars {
            if "\\`*_[]<>".unicodeScalars.contains(scalar) { escaped.append("\\") }
            escaped.unicodeScalars.append(scalar)
        }
        let scalars = escaped.unicodeScalars
        if let first = scalars.first, "#-+".unicodeScalars.contains(first) { return "\\" + escaped }
        let digits = scalars.prefix { (0x30...0x39).contains($0.value) }
        if !digits.isEmpty, scalars.dropFirst(digits.count).first == "." {
            return String(String.UnicodeScalarView(digits)) + "\\" + String(String.UnicodeScalarView(scalars.dropFirst(digits.count)))
        }
        return escaped
    }

    /// Android's `[\s\p{Z}]`: ASCII whitespace plus Unicode separators, preserving other stored scalars.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        (0x09...0x0D).contains(scalar.value) || [.spaceSeparator, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
    }

    /// S-5 suggestion only: unique export folders avoid app collisions; the share provider handles destination ones.
    public static func filename(_ title: String, untitled: String) -> String {
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map {
            $0 == "/" || $0 == "\\" || $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) ? "-" : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = "", count = 0, bytes = 0
        for scalar in replaced.unicodeScalars {
            let size = String(scalar).utf8.count
            guard count < 120, bytes + size <= 230 else { break }
            stem.unicodeScalars.append(scalar)
            count += 1; bytes += size
        }
        return (stem.isEmpty ? untitled : stem) + ".md"
    }

    /// D13 personal notes are distinct from app bookmarks. Invalid records are skipped as Android does.
    public static func notes(in manifest: JSONObject?) -> [MarkdownNote] {
        let notes = manifest?["x"]?.object?["gocassini.com"]?.object?["notes"]?.array ?? []
        return notes.compactMap {
            guard let note = $0.object, let atMs = try? note.number("atMs"), let text = note["text"]?.string else { return nil }
            return MarkdownNote(atMs: atMs, text: text)
        }
    }

    private static func clock(_ ms: Int64) -> String { String(ExportClock.srt(ms).split(separator: ",")[0]) }
}
