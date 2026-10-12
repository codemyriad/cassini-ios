import Foundation

/// Auto-follow of the active word while the note plays (Android `ReadAndListen` follow effects).
///
/// While following, a new active word scrolls its line to `anchor` of the transcript's height once it leaves the top
/// `band`. A drag during playback pauses following and shows the Follow playback chip; `resumeAfter` without scrolling
/// resumes it, and so do the chip and a word tap. A drag while paused leaves following on: there is nothing to follow.
public struct PlaybackFollow: Hashable, Sendable {
    public static let anchor = 0.3
    public static let band = 0.7
    public static let resumeAfter = Duration.seconds(4)

    public private(set) var following = true

    public init(following: Bool = true) { self.following = following }

    /// The user started dragging the transcript.
    public mutating func dragged(playing: Bool) {
        if playing { following = false }
    }

    /// The chip, a word tap, or `resumeAfter` without scrolling.
    public mutating func resume() { following = true }

    /// The Follow playback chip shows while the note plays and following is paused.
    public func showsChip(playing: Bool) -> Bool { playing && !following }

    /// The scroll that puts the active line, `lineY` from the top of a pane `height` tall, at `anchor`; nil while the
    /// line is inside the top `band`.
    public static func scroll(lineY: Double, height: Double) -> Double? {
        guard height > 0, lineY < 0 || lineY > band * height else { return nil }
        return lineY - anchor * height
    }
}
