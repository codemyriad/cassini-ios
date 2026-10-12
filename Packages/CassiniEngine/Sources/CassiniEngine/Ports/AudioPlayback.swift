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
    /// Opens `url` paused, in place of any open file. It keeps the audio session as it is, so a file swapped while
    /// playing (`PlaybackController.reload`) gives nothing back to other apps.
    func load(url: URL, at position: TimeInterval, title: String) throws
    /// Lets go of the file and gives the audio session back.
    func unload()
    func play() throws
    func pause()
    func seek(_ position: TimeInterval)
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }
}
