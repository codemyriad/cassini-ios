import Foundation

public enum PlaybackStatus: Hashable, Sendable {
    case idle
    case paused
    case playing
    case failed
}

/// A speaker sample being played, and where to go back to after it.
public struct PlaybackSample: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var restorePosition: TimeInterval
    public var restorePlaying: Bool
    public init(start: TimeInterval, end: TimeInterval, restorePosition: TimeInterval, restorePlaying: Bool) {
        self.start = start; self.end = end; self.restorePosition = restorePosition; self.restorePlaying = restorePlaying
    }
}

public struct PlaybackState: Hashable, Sendable {
    /// The note whose audio is loaded.
    public var noteID: UUID?
    public var status: PlaybackStatus
    public var position: TimeInterval
    public var duration: TimeInterval
    public var rate: Float
    public var sample: PlaybackSample?

    public init(noteID: UUID? = nil, status: PlaybackStatus = .idle, position: TimeInterval = 0, duration: TimeInterval = 0,
                rate: Float = 1, sample: PlaybackSample? = nil) {
        self.noteID = noteID; self.status = status; self.position = position; self.duration = duration
        self.rate = rate; self.sample = sample
    }

    public var isPlaying: Bool { status == .playing }
}
