/// The SubRip export (`.srt`, features.md section 9).
public enum SrtWriter {
    /// Numbered cues from 1, separated by one blank line, with no markup. With 2 or more speakers a cue starts with
    /// `"<label>: "` when its speaker differs from the cue before it in output order, and the first cue always does.
    /// Without cues the result is a single `\n`.
    public static func write(_ t: ExportTranscript) -> String {
        let cues = SubtitleCues.build(t, labelPrefixForSrt: true)
        if cues.isEmpty { return "\n" }
        var out = ""
        for (index, cue) in cues.enumerated() {
            if index > 0 { out += "\n" }
            out += "\(index + 1)\n"
            out += ExportClock.srt(cue.startMs) + " --> " + ExportClock.srt(cue.endMs) + "\n"
            for line in cue.lines { out += line + "\n" }
        }
        return out
    }
}
