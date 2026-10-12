#if DEBUG
import Foundation
import CassiniEngine

/// A speaker with no sound: positions move only through `seek` and `advance`.
@MainActor public final class FakePlayback: AudioPlayback {
    public let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    public private(set) var loadedURL: URL?
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    public var rate: Float = 1
    /// The duration every loaded file reports.
    public var fileDuration: TimeInterval
    public var loadError: (any Error)?

    public init(fileDuration: TimeInterval = 60) {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        self.fileDuration = fileDuration
    }

    public func load(url: URL, at position: TimeInterval, title: String) throws {
        if let loadError { throw loadError }
        loadedURL = url; duration = fileDuration; isPlaying = false
        seek(position)
    }

    public func unload() { loadedURL = nil; isPlaying = false; position = 0; duration = 0 }
    public func play() throws { if loadedURL != nil { isPlaying = true } }
    public func pause() { isPlaying = false }
    public func seek(_ position: TimeInterval) { self.position = max(0, min(position, duration)) }

    /// Plays on by `seconds`, stopping at the end.
    public func advance(by seconds: TimeInterval) {
        guard isPlaying else { return }
        seek(position + seconds)
        if position >= duration { isPlaying = false }
    }

    public func send(_ event: PlaybackEvent) { continuation.yield(event) }
}
#endif
