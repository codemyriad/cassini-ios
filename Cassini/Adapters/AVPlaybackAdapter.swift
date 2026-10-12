import AVFoundation
import MediaPlayer
import CassiniAudio
import CassiniEngine

/// Playback through `AVAudioPlayer`, with Now Playing metadata and the lock-screen controls.
@MainActor final class AVPlaybackAdapter: AudioPlayback {
    static let skipInterval: TimeInterval = 15

    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private var player: AVAudioPlayer?
    private var title = ""
    private var observers: [NSObjectProtocol] = []

    var rate: Float = 1 { didSet { player?.rate = rate; updateNowPlaying() } }
    var position: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        let continuation = continuation
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { _ in continuation.yield(.remotePlay); return .success }
        commands.pauseCommand.addTarget { _ in continuation.yield(.remotePause); return .success }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        commands.skipForwardCommand.addTarget { _ in continuation.yield(.remoteSkip(Self.skipInterval)); return .success }
        commands.skipBackwardCommand.addTarget { _ in continuation.yield(.remoteSkip(-Self.skipInterval)); return .success }
        commands.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            continuation.yield(.remoteSeek(event.positionTime)); return .success
        }
        let center = NotificationCenter.default
        // The player pauses here, before the observer returns; the store hears about it from `events` afterwards.
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
        unload()
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.enableRate = true; audio.rate = rate; audio.prepareToPlay()
        player = audio; self.title = title
        seek(position)
    }

    func unload() {
        player?.stop(); player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func play() throws {
        guard let player else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        guard player.play() else { throw AudioError.unreadable }
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        updateNowPlaying()
    }

    func seek(_ position: TimeInterval) {
        player?.currentTime = max(0, min(position, duration))
        updateNowPlaying()
    }

    private func pauseAndReport(_ event: PlaybackEvent) {
        guard isPlaying else { return }
        pause()
        continuation.yield(event)
    }

    private func updateNowPlaying() {
        guard player != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Cassini", MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
    }
}
