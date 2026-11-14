import Foundation

/// The shared badges applicable to current iOS rows. Local-only statuses keep their existing labels and glyphs.
public enum RowBadge {
    public static func presentation(_ row: LibraryRow, text: StatusBadges.Text) -> BadgePresentation? {
        switch row.status {
        case .recording:
            let milliseconds = row.duration * 1_000
            let live = milliseconds.isFinite && milliseconds > 0
                ? Int64(min(milliseconds, Double(Int64.max).nextDown)) : 0
            return StatusBadges.meeting(BadgeFields(lifecycle: row.isSavingCapture ? .saving : .recording,
                                                   liveMs: live), text: text)
        case .transcribing:
            // Local jobs expose an interval, not a single integer ETA. Keep that detail in the meeting;
            // the contract's no-ETA fallback avoids inventing a conversion policy for the badge.
            return StatusBadges.transcribing(etaMinutes: nil, text: text)
        default:
            return nil
        }
    }
}
