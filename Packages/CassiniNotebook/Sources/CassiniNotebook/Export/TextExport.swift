import CassiniCore

/// The plain-text transcript export, using the same rows and interjection seams as the note.
public enum TextExport {
    public static func write(_ t: ExportTranscript, subtitle: String, emptyText: String) -> String {
        var out = t.title + "\n" + subtitle + "\n\n"
        let rows = TurnModel.rows(of: t.words.map {
            TurnModel.Word(speaker: $0.speaker, startMs: Double($0.startMs), endMs: Double($0.endMs), text: $0.text,
                           lowConfidenceSpeaker: $0.lowConfidenceSpeaker)
        }, endsBoundedByAudio: t.endsBoundedByAudio)
        if rows.isEmpty { return out + emptyText + "\n" }
        let labelled = t.speakerCount >= 2
        for (index, row) in rows.enumerated() {
            if index > 0 { out += "\n" }
            out += "[" + ExportClock.clock(Int64(row.startMs.rounded()), durationMs: t.durationMs) + "]"
            if labelled, !row.continuation, let speaker = row.speaker { out += " " + t.label(speaker) }
            if !row.over.isEmpty { out += " (over " + speakerList(row.over.map(t.label)) + ")" }
            if row.crosstalk { out += " (probably crosstalk)" }
            out += "\n" + TranscriptTurns.text(of: row.members) { t.label($0 ?? "") } + "\n"
        }
        return out
    }

    /// The viewer's English list form; exports retain their existing English structural labels.
    private static func speakerList(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
