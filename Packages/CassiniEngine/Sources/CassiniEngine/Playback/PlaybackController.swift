import Foundation
import Observation
import CassiniNotebook

/// The audio player of the Note screen, over one file at a time (Android's `PlaybackController`).
///
/// - `state` carries the position every 150 ms while playing.
/// - The position is saved every 5 s while playing, and finally (which also stores the Library preview) on pause, on
///   leave, at the end of the file and when the app goes to the background (`savePosition()`). Saves run one at a
///   time in the order they were asked for, so a 5 s save never lands after the final one; `settle()` waits for them.
/// - `open` is called by the screen that shows the player, with its `PlaybackOwner`. The same note and file again
///   only gives the player to that screen; another note leaves the open one first. `leave(owner)` does nothing while
///   another screen owns the player, so a screen that is gone cannot close a newer screen's player.
/// - `show` is what a Note screen calls: it opens the note's file, gives an open one to that screen, or reloads it
///   when the note's audio changed (the recording's compressed copy replaced the capture). `reload` opens the new file
///   at the same position and play state, keeping the audio session when it plays on.
/// - A note shown again before the final save of its leave has landed opens where it was left, not at the older
///   position stored on the note.
/// - A file that cannot be opened leaves `state.status` `.failed` for its note, with no player.
/// - Another app taking the audio and a lost output (unplugged headphones) pause.
/// - `playRange` plays a speaker sample, stops at its end and returns to the position and play state from before.
///   Nested samples keep the first restore point. A seek or a skip during a sample drops it where it is. A pause, an
///   interruption or a lost output during a sample return to the position from before, stay paused and save that
///   position; leaving or reloading during a sample uses it too.
/// - While a recording runs (`setBlocked(true)`) the player is closed and nothing opens.
@MainActor @Observable
public final class PlaybackController {
    public struct Timing: Sendable {
        public var tick: Duration
        public var saveEvery: TimeInterval
        public init(tick: Duration = .milliseconds(150), saveEvery: TimeInterval = 5) {
            self.tick = tick; self.saveEvery = saveEvery
        }
    }

    /// What the controller is built from; the app passes its adapters, tests pass fakes.
    @MainActor public struct Parts {
        public var player: any AudioPlayback
        public var positions: any PlaybackPositions
        public var ticker: any PlaybackTicking
        /// A monotonic clock in seconds, for the 5 s saves.
        public var uptime: @MainActor () -> TimeInterval
        public var timing: Timing

        public init(player: any AudioPlayback, positions: any PlaybackPositions, ticker: any PlaybackTicking = PlaybackTicker(),
                    uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    timing: Timing = Timing()) {
            self.player = player; self.positions = positions; self.ticker = ticker; self.uptime = uptime; self.timing = timing
        }
    }

    public private(set) var state = PlaybackState()
    /// While a recording runs nothing opens.
    public private(set) var isBlocked = false

    @ObservationIgnored private let parts: Parts
    @ObservationIgnored private var player: any AudioPlayback { parts.player }
    /// The file the player holds; nil when nothing is open, or the open failed.
    @ObservationIgnored private var source: PlaybackSource?
    /// The screen that opened the player last; nil after a leave.
    @ObservationIgnored private var owner: PlaybackOwner?
    @ObservationIgnored private var ticker: PlaybackTicker.Token?
    @ObservationIgnored private var lastSaved: TimeInterval = 0
    /// The last save asked for; each one waits for the one before.
    @ObservationIgnored private var saves: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// The position of each note whose last save asked for has not landed yet, so the note's stored position is old.
    @ObservationIgnored private var unsaved: [UUID: PendingSave] = [:]

    private struct PendingSave {
        let token = UUID()
        let position: TimeInterval
    }

    public init(parts: Parts) {
        self.parts = parts
        let stream = parts.player.events
        events = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
    }

    isolated deinit {
        events?.cancel()
    }

    /// The file that is open, if any.
    public var openSource: PlaybackSource? { source }

    /// The speed (an iOS extra); it stays for the next file.
    public var rate: Float {
        get { state.rate }
        set { player.rate = newValue; state.rate = newValue }
    }

    // MARK: Opening and leaving

    /// Opens `source` at `position` for `owner`. The same note and file again only gives the player to `owner`;
    /// another file leaves the open one first (with its final save). False when the file cannot be played, which
    /// leaves the note `.failed`, or while a recording runs.
    @discardableResult
    public func open(_ source: PlaybackSource, at position: TimeInterval, owner: PlaybackOwner = PlaybackOwner()) -> Bool {
        guard !isBlocked else { return false }
        self.owner = owner
        if let open = self.source, open.isSameFile(as: source) { return true }
        close()
        guard prepare(source) else { return false }
        player.seek(clamped(position))
        publish()
        return true
    }

    /// The screen `owner` shows `source`'s note, which opens at `stored`, the position saved on the note, unless its
    /// player is open already. A save of the note that has not landed yet (its leave a moment ago) wins over `stored`,
    /// so the note opens where it was left. When the note's file is open, the screen gets the player; when the note's audio changed since (another file, or the same
    /// one written again), the new file is reloaded at the same position and play state, and the screen gets the
    /// player too. False when the file cannot be played (the note is then `.failed`) or a recording runs.
    @discardableResult
    public func show(_ source: PlaybackSource, at stored: TimeInterval, owner: PlaybackOwner) -> Bool {
        if let open = self.source, open.noteID == source.noteID, !open.isSameFile(as: source), !isBlocked {
            // Another screen of the same note may own it: the player moves to this one, as an open of the same file
            // does, and keeps its position and play state.
            self.owner = owner
            return reload(source, owner: owner)
        }
        return open(source, at: unsaved[source.noteID]?.position ?? stored, owner: owner)
    }

    /// The note's audio changed (`source` is its new file): opens it again at the same position and play state, or
    /// at the position from before a sample. With an `owner`, only while that screen owns the player. False when no
    /// file of that note is open, or the new file cannot be played (the note is then `.failed`).
    @discardableResult
    public func reload(_ source: PlaybackSource, owner: PlaybackOwner? = nil) -> Bool {
        if let owner, owner != self.owner { return false }
        guard let open = self.source, open.noteID == source.noteID else { return false }
        let position = state.sample?.restorePosition ?? player.position
        let resume = state.sample?.restorePlaying ?? player.isPlaying
        stopTicker()
        state.sample = nil
        // `load` swaps the file and keeps the audio session, so playing on gives nothing back to other apps.
        self.source = nil
        guard prepare(source) else { return false }
        player.seek(clamped(position))
        if resume {
            play()
        } else {
            // A sample may have held the session.
            player.pause()
            publish()
        }
        return true
    }

    /// The screen is gone: pause, save the position (final) and let go of the file. With an `owner`, only while that
    /// screen owns the player.
    public func leave(_ owner: PlaybackOwner? = nil) {
        if let owner, owner != self.owner { return }
        self.owner = nil
        close()
    }

    /// While a recording runs the player is closed and nothing opens.
    public func setBlocked(_ blocked: Bool) {
        if blocked { leave() }
        isBlocked = blocked
    }

    // MARK: Controls

    public func play() {
        guard source != nil, !player.isPlaying else { return }
        if state.sample == nil, player.position >= player.duration { player.seek(0) }
        do { try player.play() } catch {
            // The system did not give us the audio (a call, say): stay paused, as Android does when focus is refused.
            publish()
            return
        }
        lastSaved = parts.uptime()
        startTicker()
        publish()
    }

    /// Pauses and saves the position (final). During a speaker sample, the sample ends, the position from before
    /// returns and playback stays paused.
    public func pause() {
        guard source != nil else { return }
        if state.sample != nil {
            endSample(interrupted: true)
            return
        }
        player.pause()
        stopTicker()
        publish()
        save(player.position, final: true)
    }

    public func toggle() {
        if player.isPlaying { pause() } else { play() }
    }

    /// Seeks to `position`; during a sample, the sample is dropped and the position from before is not restored.
    public func seek(to position: TimeInterval) {
        guard source != nil else { return }
        state.sample = nil
        player.seek(clamped(position))
        publish()
    }

    /// Back or forward by `seconds` (± `PlaybackSkip.interval` from the controls).
    public func skip(by seconds: TimeInterval) {
        guard source != nil else { return }
        seek(to: PlaybackSkip.target(from: player.position, by: seconds, duration: player.duration))
    }

    /// Plays `start..<end` of the open note (a speaker sample), then returns to the position and play state from
    /// before. False when `noteID` is not the open note or the range is empty.
    @discardableResult
    public func playRange(_ noteID: UUID, from start: TimeInterval, to end: TimeInterval) -> Bool {
        guard source?.noteID == noteID, end > start else { return false }
        let previous = state.sample
        let sample = PlaybackSample(start: clamped(start), end: min(end, player.duration),
                                    restorePosition: previous?.restorePosition ?? player.position,
                                    restorePlaying: previous?.restorePlaying ?? player.isPlaying)
        state.sample = sample
        player.seek(sample.start)
        if player.isPlaying {
            publish()
            return true
        }
        play()
        guard player.isPlaying else {
            // The audio was refused: there is no sample to hear.
            state.sample = nil
            player.seek(sample.restorePosition)
            publish()
            return false
        }
        return true
    }

    /// Saves where the open note is (final), without pausing: the app goes to the background.
    public func savePosition() {
        guard source != nil else { return }
        save(state.sample?.restorePosition ?? player.position, final: true)
    }

    /// Waits until every save asked for so far has landed.
    public func settle() async {
        while let pending = saves {
            await pending.value
            if saves == pending { return }
        }
    }

    // MARK: Helpers

    /// Loads `source`; on failure the note is left `.failed` with no file.
    private func prepare(_ source: PlaybackSource) -> Bool {
        do {
            try player.load(url: source.url, at: 0, title: source.title)
        } catch {
            player.unload()
            self.source = nil
            state = PlaybackState(noteID: source.noteID, status: .failed, rate: state.rate)
            return false
        }
        player.rate = state.rate
        self.source = source
        return true
    }

    /// Pauses, saves the position (final) and lets go of the open file; with none, only resets the state.
    private func close() {
        guard let open = source else {
            reset()
            return
        }
        let position = state.sample?.restorePosition ?? player.position
        player.pause()
        stopTicker()
        player.unload()
        reset()
        save(position, of: open.noteID, final: true)
    }

    private func reset() {
        source = nil
        state = PlaybackState(rate: state.rate)
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .interrupted, .routeLost:
            // The adapter paused already; a tick may have seen it first.
            if state.isPlaying || state.sample != nil { pause() }
        case .remotePlay: play()
        case .remotePause: pause()
        case .remoteSkip(let seconds): skip(by: seconds)
        case .remoteSeek(let position): seek(to: position)
        }
    }

    private func tick() {
        guard source != nil else { return }
        let position = player.position
        if let sample = state.sample, position >= sample.end {
            endSample(interrupted: false)
            return
        }
        guard player.isPlaying else {
            // The end of the file, or the system stopped the player.
            if position >= player.duration { finish() } else { pause() }
            return
        }
        publish()
        let now = parts.uptime()
        if state.sample == nil, now - lastSaved >= parts.timing.saveEvery {
            lastSaved = now
            save(position, final: false)
        }
    }

    /// The end of the file: paused there, with a final save of the duration.
    private func finish() {
        if state.sample != nil {
            endSample(interrupted: false)
            return
        }
        player.pause()
        stopTicker()
        publish()
        save(player.duration, final: true)
    }

    /// Ends the sample at the position from before. At the sample's end (`interrupted` false), playback goes on if it
    /// played before. A pause, an interruption or a lost output keep it paused and save that position.
    private func endSample(interrupted: Bool) {
        guard let ended = state.sample else { return }
        state.sample = nil
        player.seek(ended.restorePosition)
        if !interrupted, ended.restorePlaying {
            if player.isPlaying {
                // The 5 s saves count from here, as they do from a play.
                lastSaved = parts.uptime()
                publish()
            } else {
                play()
            }
            return
        }
        player.pause()
        stopTicker()
        publish()
        if interrupted { save(ended.restorePosition, final: true) }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = parts.ticker.start(every: parts.timing.tick) { [weak self] in self?.tick() }
    }

    private func stopTicker() {
        if let ticker { parts.ticker.stop(ticker) }
        ticker = nil
    }

    private func publish() {
        guard let source else { return }
        state = PlaybackState(noteID: source.noteID, status: player.isPlaying ? .playing : .paused,
                              position: player.position, duration: player.duration, rate: state.rate, sample: state.sample)
    }

    private func clamped(_ position: TimeInterval) -> TimeInterval { min(max(0, position), player.duration) }

    private func save(_ position: TimeInterval, final: Bool) {
        guard let id = source?.noteID else { return }
        save(position, of: id, final: final)
    }

    /// Queues the save behind the ones asked for before it; until it lands, an open of the note starts there.
    private func save(_ position: TimeInterval, of noteID: UUID, final: Bool) {
        let previous = saves
        let positions = parts.positions
        let pending = PendingSave(position: position)
        unsaved[noteID] = pending
        saves = Task { [weak self] in
            await previous?.value
            await positions.save(noteID, position: position, final: final)
            if self?.unsaved[noteID]?.token == pending.token { self?.unsaved[noteID] = nil }
        }
    }
}
