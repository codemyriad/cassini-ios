import Foundation

/// Where playback positions go. The app saves them to the note through the Library, so the screens show them.
@MainActor public protocol PlaybackPositions: AnyObject {
    /// Saves `position` for the note. A `final` save (pause, leave, the end of the file, going to the background) also
    /// stores the Library preview at that position.
    func save(_ noteID: UUID, position: TimeInterval, final: Bool) async
}

/// A repeating timer on the main actor.
@MainActor public protocol PlaybackTicking: AnyObject {
    /// Calls `tick` every `interval` until `stop(_:)` is called with the returned token.
    func start(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> PlaybackTicker.Token
    func stop(_ token: PlaybackTicker.Token)
}

/// A `Timer` in the main run loop's common modes, so it keeps ticking while the slider is dragged.
@MainActor public final class PlaybackTicker: PlaybackTicking {
    public struct Token: Hashable, Sendable {
        let id = UUID()
        public init() {}
    }

    private var timers: [Token: Timer] = [:]

    public init() {}

    public func start(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> Token {
        let token = Token()
        let seconds = TimeInterval(interval.components.seconds) + TimeInterval(interval.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        timers[token] = timer
        return token
    }

    public func stop(_ token: Token) {
        timers.removeValue(forKey: token)?.invalidate()
    }
}

/// One audio file of one note, as the player opens it.
public struct PlaybackSource: Hashable, Sendable {
    public var noteID: UUID
    public var url: URL
    /// The title on the lock screen.
    public var title: String
    /// What tells this file apart from another one written under the same name (its size and modification date); a
    /// change makes the player open the file again.
    public var signature: String?

    public init(noteID: UUID, url: URL, title: String, signature: String? = nil) {
        self.noteID = noteID; self.url = url; self.title = title; self.signature = signature
    }

    /// Whether `other` is the same file of the same note; the title may differ.
    func isSameFile(as other: PlaybackSource) -> Bool {
        noteID == other.noteID && url == other.url && signature == other.signature
    }
}

/// One screen that shows the player (Android's `owner`). Each Note screen makes its own; a screen that is gone cannot
/// take the player from a newer one.
public struct PlaybackOwner: Hashable, Sendable {
    let id = UUID()
    public init() {}
}
