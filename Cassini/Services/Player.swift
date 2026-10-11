import AVFoundation
import MediaPlayer
import Observation
import CassiniNotebook

@MainActor @Observable final class Player {
    private(set) var noteID: UUID?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1 { didSet { player?.rate = rate; updateNowPlaying() } }
    var onPositionSaved: ((UUID, Double) -> Void)?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var title = ""
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    init() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in try? self?.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(15) }; return .success }
        commands.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(time) }; return .success
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        }
    }
    func load(_ note: Note, url: URL) throws {
        guard noteID != note.id else { return }
        stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.enableRate = true; audio.rate = rate; audio.prepareToPlay()
        player = audio; duration = audio.duration; title = note.title; noteID = note.id
        seek(note.playbackPosition)
    }
    func play() throws {
        guard let player else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        if position >= duration - 0.1 { seek(0) }
        guard player.play() else { throw AudioError.unreadable }
        isPlaying = true; updateNowPlaying()
        timer?.invalidate()
        let playbackTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying { self.pause() }
            }
        }
        timer = playbackTimer
        RunLoop.main.add(playbackTimer, forMode: .common)
    }
    func pause() {
        player?.pause(); isPlaying = false; timer?.invalidate(); timer = nil
        if let noteID { onPositionSaved?(noteID, position) }
        updateNowPlaying()
    }
    func seek(_ value: Double) {
        position = max(0, min(value, duration)); player?.currentTime = position; updateNowPlaying()
    }
    func skip(_ seconds: Double) { seek(position + seconds) }
    func stop() {
        pause(); player?.stop(); player = nil; noteID = nil; position = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func updateNowPlaying() {
        guard noteID != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Cassini", MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
    }
}
