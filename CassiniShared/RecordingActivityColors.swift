import SwiftUI

/// The Live Activity's colours, shared with the app so `ContrastTests` checks them: the Lock Screen card is always
/// dark, whatever the appearance.
enum RecordingActivityColors {
    static let background = Color(red: 0.075, green: 0.12, blue: 0.14)
    static let live = Color(red: 0.98, green: 0.49, blue: 0.30)
    static let finish = Color(red: 0.78, green: 0.24, blue: 0.12)
    /// The "Recording" caption and the paused dot's ring.
    static let secondary = Color.white.opacity(0.7)
    /// Pause and Resume.
    static let button = Color.white.opacity(0.18)
}
