/// The time stamps of the exports (features.md sections 0 and 9). Negative times are written as 0.
public enum ExportClock {
    private static let secondMs: Int64 = 1000
    private static let minuteMs: Int64 = 60 * secondMs
    private static let hourMs: Int64 = 60 * minuteMs

    /// The TXT clock of `ms`: `mm:ss` when `durationMs` is below 1 h, else `h:mm:ss`; seconds are floored. A time of
    /// 1 h or more also uses `h:mm:ss`, so a duration that is too short never gives a minute count over 59.
    public static func clock(_ ms: Int64, durationMs: Int64) -> String {
        let t = max(ms, 0)
        if durationMs >= hourMs || t >= hourMs {
            return "\(t / hourMs):\(pad(minutes(t), 2)):\(pad(seconds(t), 2))"
        }
        return "\(pad(minutes(t), 2)):\(pad(seconds(t), 2))"
    }

    /// The SRT time stamp `HH:MM:SS,mmm`.
    public static func srt(_ ms: Int64) -> String { stamp(ms, separator: ",") }

    /// The WebVTT time stamp `HH:MM:SS.mmm`.
    public static func vtt(_ ms: Int64) -> String { stamp(ms, separator: ".") }

    private static func minutes(_ t: Int64) -> Int64 { t / minuteMs % 60 }
    private static func seconds(_ t: Int64) -> Int64 { t / secondMs % 60 }

    private static func stamp(_ ms: Int64, separator: String) -> String {
        let t = max(ms, 0)
        return "\(pad(t / hourMs, 2)):\(pad(minutes(t), 2)):\(pad(seconds(t), 2))\(separator)\(pad(t % secondMs, 3))"
    }

    /// `value` with leading zeros up to `width` digits; wider values are written in full.
    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
