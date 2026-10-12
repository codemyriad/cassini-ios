/// The WebVTT export (`.vtt`, features.md section 9).
public enum VttWriter {
    /// The `WEBVTT` header and one cue per `SubtitleCues` cue, without cue ids, STYLE or REGION blocks. With 2 or
    /// more speakers every cue is wrapped in a `<v Label>…</v>` span. `&`, `<` and `>` are escaped in text and labels,
    /// and labels lose their control characters (so `-->` in a label is written `--&gt;`).
    public static func write(_ t: ExportTranscript) -> String {
        var out = "WEBVTT\n"
        let voiced = t.speakerCount >= 2
        for cue in SubtitleCues.build(t, labelPrefixForSrt: false) {
            out += "\n" + ExportClock.vtt(cue.startMs) + " --> " + ExportClock.vtt(cue.endMs) + "\n"
            let text = cue.lines.map(escape).joined(separator: "\n")
            if voiced {
                out += "<v " + escape(cleanLabel(cue.label)) + ">" + text + "</v>\n"
            } else {
                out += text + "\n"
            }
        }
        return out
    }

    private static func cleanLabel(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.filter { !ExportNames.isControl($0) }))
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
