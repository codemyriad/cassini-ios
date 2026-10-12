#if DEBUG
import Foundation
import CassiniEngine

/// Timers on virtual time: nothing ticks until `advance(byMilliseconds:)`, which fires each timer at its due times in
/// order and moves `onAdvance` (a fake player, say) along with the clock between them.
@MainActor public final class ManualTicker: PlaybackTicking {
    private struct Timer {
        var interval: Int
        var next: Int
        var tick: @MainActor () -> Void
    }

    /// Virtual time in milliseconds.
    public private(set) var now = 0
    /// Called with the seconds that passed, before each tick and at the end of an advance.
    public var onAdvance: (@MainActor (TimeInterval) -> Void)?
    private var timers: [PlaybackTicker.Token: Timer] = [:]

    public init() {}

    public var isRunning: Bool { !timers.isEmpty }
    public var seconds: TimeInterval { TimeInterval(now) / 1000 }

    public func start(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> PlaybackTicker.Token {
        let token = PlaybackTicker.Token()
        let milliseconds = Int(interval.components.seconds) * 1000 + Int(interval.components.attoseconds / 1_000_000_000_000_000)
        timers[token] = Timer(interval: milliseconds, next: now + milliseconds, tick: tick)
        return token
    }

    public func stop(_ token: PlaybackTicker.Token) { timers[token] = nil }

    public func advance(byMilliseconds milliseconds: Int) {
        let end = now + milliseconds
        while let (token, timer) = timers.filter({ $0.value.next <= end }).min(by: { $0.value.next < $1.value.next }) {
            move(to: timer.next)
            timers[token]?.next += timer.interval
            timer.tick()
        }
        move(to: end)
    }

    private func move(to time: Int) {
        guard time > now else { return }
        let step = TimeInterval(time - now) / 1000
        now = time
        onAdvance?(step)
    }
}

/// Where a test's playback positions go: every save, in the order it landed. `hold()` makes saves wait until
/// `release()`.
@MainActor public final class FakePlaybackPositions: PlaybackPositions {
    public struct Save: Hashable, Sendable, CustomStringConvertible {
        public var noteID: UUID
        public var position: TimeInterval
        public var final: Bool
        public init(_ noteID: UUID, _ position: TimeInterval, final: Bool) {
            // Whole milliseconds, so positions summed from 150 ms ticks compare as Android's do.
            self.noteID = noteID; self.position = (position * 1000).rounded() / 1000; self.final = final
        }
        /// The position in whole milliseconds.
        public var milliseconds: Int { Int((position * 1000).rounded()) }
        public var description: String { "\(noteID.uuidString.prefix(4)) @\(milliseconds) ms\(final ? " final" : "")" }
    }

    public private(set) var saves: [Save] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false

    public init() {}

    public func save(_ noteID: UUID, position: TimeInterval, final: Bool) async {
        if held { await withCheckedContinuation { gate = $0 } }
        saves.append(Save(noteID, position, final: final))
    }

    public func hold() { held = true }

    public func release() {
        held = false
        gate?.resume(); gate = nil
    }
}
/// A `FakePlayback` with the audio session of the real adapter: taken on `play()`, kept when `load` swaps the file,
/// and given back on pause, unload and the end of the file. It counts loads, unloads and session releases, and can
/// refuse files.
@MainActor public final class SessionPlayback: AudioPlayback {
    public let base: FakePlayback
    /// Files that cannot be played: loading one throws.
    public var unplayable: Set<URL> = []
    /// Every file loaded, in order.
    public private(set) var loads: [URL] = []
    /// How often a loaded file was let go of.
    public private(set) var unloads = 0
    /// Whether the audio session is held.
    public private(set) var holdsSession = false
    /// How often the session was given back to other apps.
    public private(set) var sessionReleases = 0

    public init(fileDuration: TimeInterval = 60) { base = FakePlayback(fileDuration: fileDuration) }

    public var events: AsyncStream<PlaybackEvent> { base.events }
    public var loadedURL: URL? { base.loadedURL }
    public var position: TimeInterval { base.position }
    public var duration: TimeInterval { base.duration }
    public var isPlaying: Bool { base.isPlaying }
    public var rate: Float {
        get { base.rate }
        set { base.rate = newValue }
    }

    /// Replaces the open file, paused; the session stays as it was.
    public func load(url: URL, at position: TimeInterval, title: String) throws {
        if unplayable.contains(url) { throw CocoaError(.fileReadCorruptFile) }
        try base.load(url: url, at: position, title: title)
        loads.append(url)
    }

    public func unload() {
        if base.loadedURL != nil { unloads += 1 }
        base.unload()
        releaseSession()
    }

    public func play() throws {
        guard base.loadedURL != nil else { return }
        try base.play()
        holdsSession = true
    }

    public func pause() {
        base.pause()
        releaseSession()
    }

    public func seek(_ position: TimeInterval) { base.seek(position) }

    /// Plays on by `seconds`; at the end of the file the session is given back.
    public func advance(by seconds: TimeInterval) {
        base.advance(by: seconds)
        if !base.isPlaying, base.loadedURL != nil, base.position >= base.duration { releaseSession() }
    }

    public func send(_ event: PlaybackEvent) { base.send(event) }

    /// The headphones go or the app pauses for an interruption: the player pauses at once and the event follows.
    public func interrupt(_ event: PlaybackEvent = .interrupted) {
        guard isPlaying else { return }
        pause()
        send(event)
    }

    /// The system paused the player itself (another app took the audio): the player stops with the session still
    /// counted as held, and only then does the event arrive, as `AVAudioPlayer` does.
    public func systemInterrupt(_ event: PlaybackEvent = .interrupted) {
        base.pause()
        send(event)
    }

    private func releaseSession() {
        guard holdsSession else { return }
        holdsSession = false
        sessionReleases += 1
    }
}
#endif
