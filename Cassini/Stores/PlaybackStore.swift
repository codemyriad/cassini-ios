import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// One player for the whole app: which note is loaded, where it is, and saving that position.
@MainActor @Observable final class PlaybackStore {
    private(set) var state = PlaybackState()

    @ObservationIgnored private let playback: any AudioPlayback
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var sample: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// While a recording runs nothing plays.
    @ObservationIgnored private var isBlocked = false

    init(playback: any AudioPlayback, library: LibraryStore, errors: ErrorPresenter, clock: any AppClock) {
        self.playback = playback; self.library = library; self.errors = errors; self.clock = clock
        let stream = playback.events
        events = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
    }

    var rate: Float {
        get { state.rate }
        set { playback.rate = newValue; state.rate = newValue }
    }

    /// Loads the note at its saved position, unless it is loaded already.
    func load(_ note: Note) {
        guard !isBlocked, state.noteID != note.id, note.audio.isPlayable, let url = library.audioURL(note) else { return }
        stop()
        do {
            try playback.load(url: url, at: note.playbackPosition, title: note.title)
            state = PlaybackState(noteID: note.id, status: .paused, position: playback.position, duration: playback.duration, rate: state.rate)
        } catch {
            errors.present(error.localizedDescription)
        }
    }

    func togglePlayback() {
        if state.isPlaying { pause() } else { play() }
    }

    func play() {
        guard state.noteID != nil else { return }
        if state.position >= state.duration - 0.1 { seek(0) }
        do {
            try playback.play()
            state.status = .playing
            startTicker()
        } catch {
            errors.present(error.localizedDescription)
        }
    }

    /// Pauses and saves the position.
    func pause() {
        cancelSample()
        playback.pause()
        stopTicker()
        if state.noteID != nil { state.status = .paused }
        savePosition()
    }

    func seek(_ position: TimeInterval) {
        state.position = max(0, min(position, state.duration))
        playback.seek(state.position)
    }

    func skip(_ seconds: TimeInterval) { seek(state.position + seconds) }

    /// Opens `note` at `time` and plays from there.
    func play(_ note: Note, from time: TimeInterval) {
        load(note)
        guard state.noteID == note.id else { return }
        seek(time)
        if !state.isPlaying { play() }
    }

    /// Plays `duration` seconds of `note` from `start`, then pauses.
    func playSample(_ note: Note, from start: TimeInterval, duration: TimeInterval) {
        cancelSample()
        play(note, from: start)
        guard state.isPlaying else { return }
        let clock = clock
        sample = Task { [weak self] in
            try? await clock.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.pause()
        }
    }

    func cancelSample() {
        sample?.cancel(); sample = nil
    }

    /// Stops and unloads, saving the position first.
    func stop() {
        pause()
        playback.unload()
        state = PlaybackState(rate: state.rate)
    }

    /// Stops playback while a recording runs, and keeps it stopped until it ends.
    func setBlocked(_ blocked: Bool) {
        if blocked { stop() }
        isBlocked = blocked
    }

    func savePosition() {
        guard let id = state.noteID else { return }
        let position = state.position
        library.update(id) { $0.playbackPosition = position }
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .interrupted, .routeLost, .remotePause: pause()
        case .remotePlay: play()
        case .remoteSkip(let seconds): skip(seconds)
        case .remoteSeek(let position): seek(position)
        }
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTicker() {
        ticker?.invalidate(); ticker = nil
    }

    private func tick() {
        state.position = playback.position
        if !playback.isPlaying { pause() }
    }
}
