import Foundation

public enum PlaybackEvent: Hashable, Sendable {
    /// The audio session was interrupted.
    case interrupted
    /// The output in use went away.
    case routeLost
    /// Lock-screen and headphone controls.
    case remotePlay
    case remotePause
    case remoteSkip(TimeInterval)
    case remoteSeek(TimeInterval)
}

/// The speaker, playing one file at a time, with its lock-screen controls.
@MainActor public protocol AudioPlayback: AnyObject {
    var events: AsyncStream<PlaybackEvent> { get }
    func load(url: URL, at position: TimeInterval, title: String) throws
    func unload()
    func play() throws
    func pause()
    func seek(_ position: TimeInterval)
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }
}
