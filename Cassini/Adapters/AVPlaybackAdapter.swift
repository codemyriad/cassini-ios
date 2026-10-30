import AVFoundation
import MediaPlayer
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// Playback through `AVAudioPlayer`, with Now Playing metadata and the lock-screen controls (iOS extras).
///
/// - The audio session is taken on `play()` and given back on pause and unload with `.notifyOthersOnDeactivation`, so
///   the audio another app was playing resumes. Both happen off the main thread, in order (`AudioSession`). `load` swaps the file and keeps the session, so a reload that plays on
///   does not hand the audio to other apps for a moment.
/// - Only the start of an interruption pauses (never its end), and so does losing the output in use (unplugged
///   headphones). The system has usually paused the player already when an interruption begins, so the event is sent
///   whether or not it was still playing; the controller ignores it when it was paused.
/// - At the end of the file the position stays at the end, so the controller saves the duration.
@MainActor final class AVPlaybackAdapter: AudioPlayback {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private var player: AVAudioPlayer?
    private let ending = PlayerEnding()
    private var title = ""
    private var observers: [NSObjectProtocol] = []
    /// Whether this adapter activated the audio session and has not given it back.
    private var holdsSession = false
    /// The player reached the end of the file by itself.
    private var finished = false

    var rate: Float = 1 { didSet { player?.rate = rate; updateNowPlaying() } }
    var position: TimeInterval {
        guard let player else { return 0 }
        return finished ? player.duration : player.currentTime
    }
    var duration: TimeInterval { player?.duration ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        let continuation = continuation
        let skip = NSNumber(value: PlaybackSkip.interval)
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { _ in continuation.yield(.remotePlay); return .success }
        commands.pauseCommand.addTarget { _ in continuation.yield(.remotePause); return .success }
        commands.skipForwardCommand.preferredIntervals = [skip]
        commands.skipBackwardCommand.preferredIntervals = [skip]
        commands.skipForwardCommand.addTarget { _ in continuation.yield(.remoteSkip(PlaybackSkip.interval)); return .success }
        commands.skipBackwardCommand.addTarget { _ in continuation.yield(.remoteSkip(-PlaybackSkip.interval)); return .success }
        commands.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            continuation.yield(.remoteSeek(event.positionTime)); return .success
        }
        ending.onFinish = { [weak self] in self?.reachedEnd() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.pauseAndReport(.interrupted) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.pauseAndReport(.routeLost) }
        })
    }

    func load(url: URL, at position: TimeInterval, title: String) throws {
        closePlayer()
        let audio = try AVAudioPlayer(contentsOf: url)
        // The rate only takes effect when it is enabled before the player is prepared.
        audio.enableRate = true; audio.rate = rate; audio.delegate = ending
        guard audio.duration > 0, audio.prepareToPlay() else { throw AudioError.unreadable }
        player = audio; self.title = title
        seek(position)
    }

    func unload() {
        closePlayer()
        releaseSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func play() throws {
        guard let player else { return }
        // Off the main thread (`AudioSession`); a session that cannot be had stops playback as an interruption does.
        AudioSession.activateForPlayback { [weak self] error in if error != nil { self?.pauseAndReport(.interrupted) } }
        holdsSession = true
        if finished { player.currentTime = 0; finished = false }
        guard player.play() else {
            releaseSession()
            throw AudioError.unreadable
        }
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        releaseSession()
        updateNowPlaying()
    }

    func seek(_ position: TimeInterval) {
        guard let player else { return }
        finished = false
        player.currentTime = max(0, min(position, player.duration))
        updateNowPlaying()
    }

    private func pauseAndReport(_ event: PlaybackEvent) {
        guard player != nil else { return }
        pause()
        continuation.yield(event)
    }

    /// Stops and drops the open player, keeping the audio session and the Now Playing entry.
    private func closePlayer() {
        player?.stop(); player = nil
        finished = false
    }

    private func reachedEnd() {
        finished = true
        releaseSession()
        updateNowPlaying()
    }

    /// Gives the audio back to other apps.
    private func releaseSession() {
        guard holdsSession else { return }
        holdsSession = false
        AudioSession.deactivate()
    }

    private func updateNowPlaying() {
        guard player != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: ProductName.full, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
    }
}

/// The player's delegate: `AVAudioPlayer` tells it, on the main thread, when a file plays to its end.
@MainActor private final class PlayerEnding: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { onFinish?() }
        } else {
            Task { @MainActor in self.onFinish?() }
        }
    }
}
