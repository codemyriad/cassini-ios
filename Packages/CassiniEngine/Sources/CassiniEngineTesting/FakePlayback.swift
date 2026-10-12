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
    /// Files that cannot be played: loading one throws.
    public var unplayable: Set<URL> = []
    /// Every file loaded, in order.
    public private(set) var loads: [URL] = []
    /// How often a loaded file was let go of.
    public private(set) var unloads = 0
    /// Whether the audio session is held, as the real adapter holds it: from `play()` until the next pause or unload.
    public private(set) var holdsSession = false

    public init(fileDuration: TimeInterval = 60) {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        self.fileDuration = fileDuration
    }

    public func load(url: URL, at position: TimeInterval, title: String) throws {
        if let loadError { throw loadError }
        if unplayable.contains(url) { throw CocoaError(.fileReadCorruptFile) }
        loadedURL = url; duration = fileDuration; isPlaying = false
        loads.append(url)
        seek(position)
    }

    public func unload() {
        if loadedURL != nil { unloads += 1 }
        loadedURL = nil; isPlaying = false; position = 0; duration = 0; holdsSession = false
    }

    public func play() throws {
        guard loadedURL != nil else { return }
        isPlaying = true; holdsSession = true
    }

    public func pause() { isPlaying = false; holdsSession = false }
    public func seek(_ position: TimeInterval) { self.position = max(0, min(position, duration)) }

    /// Plays on by `seconds`, stopping at the end.
    public func advance(by seconds: TimeInterval) {
        guard isPlaying else { return }
        seek(position + seconds)
        if position >= duration { isPlaying = false }
    }

    public func send(_ event: PlaybackEvent) { continuation.yield(event) }

    /// Another app takes the audio, or the headphones go: like the real adapter, the player pauses at once and the
    /// event follows.
    public func interrupt(_ event: PlaybackEvent = .interrupted) {
        guard isPlaying else { return }
        pause()
        send(event)
    }
}
#endif
