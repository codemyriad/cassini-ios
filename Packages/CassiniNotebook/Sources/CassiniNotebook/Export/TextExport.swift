import CassiniCore

/// The plain-text transcript export (`.txt`, features.md section 9).
public enum TextExport {
    /// The title line, the `subtitle` line ("8 Oct 2026, 15:10 · 23:50 · 3 speakers", made by the caller), a blank
    /// line, then one block per turn: `[<clock>] <label>` and the turn's words on the next line. Blocks are separated
    /// by one blank line. With one distinct speaker the label is left out (`[<clock>]` only). Without words the body
    /// is `emptyText`. The result uses `\n` line endings and ends with exactly one `\n`.
    public static func write(_ t: ExportTranscript, subtitle: String, emptyText: String) -> String {
        var out = t.title + "\n" + subtitle + "\n\n"
        let turns = Turn.of(t.words)
        if turns.isEmpty { return out + emptyText + "\n" }
        let labelled = t.speakerCount >= 2
        for (index, turn) in turns.enumerated() {
            if index > 0 { out += "\n" }
            out += "[" + ExportClock.clock(turn.startMs, durationMs: t.durationMs) + "]"
            if labelled { out += " " + t.label(turn.speaker) }
            out += "\n" + turn.text + "\n"
        }
        return out
    }

    /// A maximal run of consecutive words (canonical order) with the same speaker. It starts at its first word's
    /// start, even when an earlier word of the turn ends later.
    struct Turn {
        let speaker: String
        let startMs: Int64
        let text: String

        static func of(_ words: [Word]) -> [Turn] {
            var turns: [Turn] = []
            var from = 0
            while from < words.count {
                var to = from + 1
                while to < words.count && words[to].speaker == words[from].speaker { to += 1 }
                turns.append(Turn(speaker: words[from].speaker, startMs: words[from].startMs,
                                  text: words[from..<to].lazy.map(\.text).joined(separator: " ")))
                from = to
            }
            return turns
        }
    }
}
