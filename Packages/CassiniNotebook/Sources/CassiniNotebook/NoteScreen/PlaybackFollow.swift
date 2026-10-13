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

    /// What the transcript's scroll is doing, as far as following cares.
    public enum Scrolling: Hashable, Sendable {
        /// The user's finger is on it.
        case dragging
        /// It came to rest.
        case idle
        /// It moves by itself (a fling, an animation).
        case moving
    }

    /// What the resume timer does after a change of `Scrolling`.
    public enum ResumeTimer: Hashable, Sendable {
        case keep
        case cancel
        /// Cancel any running one and resume following once this much time passed without scrolling.
        case restart(Duration)
    }

    /// The scroll changed: a drag cancels the timer and pauses following while `playing`; a scroll that comes to
    /// rest while following is paused starts `resumeAfter`.
    public mutating func scrolled(_ scrolling: Scrolling, playing: Bool) -> ResumeTimer {
        switch scrolling {
        case .dragging:
            dragged(playing: playing)
            return .cancel
        case .idle where !following: return .restart(Self.resumeAfter)
        case .idle, .moving: return .keep
        }
    }

    /// The Follow playback chip shows while the note plays and following is paused.
    public func showsChip(playing: Bool) -> Bool { playing && !following }

    /// The scroll that puts the active line, `lineY` from the top of a pane `height` tall, at `anchor`; nil while the
    /// line is inside the top `band`.
    public static func scroll(lineY: Double, height: Double) -> Double? {
        guard height > 0, lineY < 0 || lineY > band * height else { return nil }
        return lineY - anchor * height
    }

    /// Whether a search match's line, `lineY` from the top of a pane `height` tall and about `lineHeight` tall, is in
    /// view already, so revealing it scrolls nothing.
    public static func isInView(lineY: Double, lineHeight: Double, height: Double) -> Bool {
        height > 0 && lineY >= 0 && lineY + lineHeight <= height
    }
}
