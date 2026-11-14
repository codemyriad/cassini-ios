import CassiniCore
import Foundation

/// D99 / PARITY §2 derivatives. The older Android writers remain for historical conformance fixtures.
/// Shared TXT/SRT/VTT goldens have not yet landed at the pinned upstream commit.
public enum AlignedTextExport {
    public static func plainText(_ t: ExportTranscript) -> String {
        turns(t).map { turn in
            t.label(turn[0].speaker) + " · " + clock(turn[0].startMs) + "\n"
                + turn.map(\.text).joined(separator: " ")
        }.joined(separator: "\n\n") + "\n"
    }

    public static func subtitles(_ t: ExportTranscript, webVTT: Bool) -> String {
        let cues = cues(t)
        var blocks: [String] = []
        if webVTT { blocks.append("WEBVTT") }
        for (index, cue) in cues.enumerated() {
            let label = t.label(cue.speaker)
            let prefix = webVTT ? "" : label + ": "
            let lines = SubtitleCues.lines(prefix + cue.text, from: prefix.utf16.count)
            let body: String
            if webVTT {
                let safeLabel = String(String.UnicodeScalarView(label.unicodeScalars.filter { !ExportNames.isControl($0) }))
                body = "<v " + escape(safeLabel) + ">" + lines.map(escape).joined(separator: "\n") + "</v>"
            } else { body = lines.joined(separator: "\n") }
            let start = webVTT ? ExportClock.vtt(cue.startMs) : ExportClock.srt(cue.startMs)
            let end = webVTT ? ExportClock.vtt(cue.endMs) : ExportClock.srt(cue.endMs)
            blocks.append((webVTT ? "" : "\(index + 1)\n") + start + " --> " + end + "\n" + body)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The same segmentation for both subtitle formats, including the visible SRT speaker prefix budget.
    /// Canonical order is retained; overlap is flattened forward so every cue has a positive, disjoint range.
    public static func cues(_ t: ExportTranscript) -> [Cue] {
        var result: [Cue] = []
        for turn in turns(t) {
            var group: [Word] = []
            func appendGroup() {
                guard let first = group.first else { return }
                let start = max(max(0, first.startMs), result.last?.endMs ?? 0)
                let end = max(start + 1, min(start + 7_000, group.map(\.endMs).max() ?? start + 1))
                let text = group.map(\.text).joined(separator: " ")
                result.append(Cue(speaker: first.speaker, label: t.label(first.speaker), startMs: start,
                                  endMs: end, text: text, prefix: t.label(first.speaker) + ": ", lines: []))
                group = []
            }
            for word in turn {
                if let first = group.first {
                    let proposed = t.label(first.speaker) + ": " + (group.map(\.text) + [word.text]).joined(separator: " ")
                    let lines = SubtitleCues.lines(proposed, from: (t.label(first.speaker) + ": ").utf16.count)
                    if word.endMs - first.startMs > 7_000 || lines.contains(where: { $0.utf16.count > 42 }) {
                        appendGroup()
                    }
                }
                group.append(word)
            }
            appendGroup()
        }
        return result
    }

    private static func turns(_ t: ExportTranscript) -> [[Word]] {
        var turns: [[Word]] = []
        for word in t.words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = turns.last, Data(last[0].speaker.utf8) == Data(word.speaker.utf8) {
                turns[turns.count - 1].append(word)
            } else { turns.append([word]) }
        }
        return turns
    }
    private static func clock(_ ms: Int64) -> String { String(ExportClock.srt(ms).prefix { $0 != "," }) }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
