import AVFoundation
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// The microphone through `AVAudioRecorder`, writing 48 kHz 16-bit mono PCM into CAF.
@MainActor final class AVCaptureAdapter: NSObject, AudioCapture, AVAudioRecorderDelegate {
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isPaused = false

    override init() {
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.pauseAndReport(.interrupted) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.pauseAndReport(.routeLost) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recorder != nil else { return }
                self.continuation.yield(.mediaReset)
            }
        })
    }

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    var fileBytes: Int64 {
        guard let url = recorder?.url else { return 0 }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func start(url: URL) async throws -> CaptureFormat {
        guard recorder == nil else { throw AudioError.busy }
        guard await AVAudioApplication.requestRecordPermission() else { throw AudioError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            guard session.isInputAvailable else { throw AudioError.noInput }
            try session.setActive(true)
            // PCM in CAF stays readable if the process dies before stop() can finalize it.
            let capture = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            capture.isMeteringEnabled = true; capture.delegate = self
            guard capture.record() else { throw AudioError.startFailed }
            recorder = capture; isPaused = false
            let meterTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer = meterTimer
            RunLoop.main.add(meterTimer, forMode: .common)
            return .pcm48kMono
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw (error as? AudioError) ?? .startFailed
        }
    }

    func pause() {
        guard let recorder, !isPaused else { return }
        recorder.pause(); isPaused = true
    }

    func resume() throws {
        guard let recorder else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        guard recorder.record() else { throw AudioError.startFailed }
        isPaused = false
    }

    func stop() async throws -> CaptureResult {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop(); timer?.invalidate(); timer = nil; recorder = nil; isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return CaptureResult(duration: duration)
    }

    private func tick() {
        guard let recorder, !isPaused else { return }
        recorder.updateMeters()
        continuation.yield(.level(max(0.04, min(1, pow(10, recorder.averagePower(forChannel: 0) / 35)))))
    }

    private func pauseAndReport(_ event: CaptureEvent) {
        guard recorder != nil else { return }
        pause()
        continuation.yield(event)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor in self.reportFailure(of: identity) }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor in self.reportFailure(of: identity) }
    }

    /// The recorder stopped without `stop()`: the capture is over, and what was written stays.
    private func reportFailure(of identity: ObjectIdentifier) {
        guard let current = recorder, ObjectIdentifier(current) == identity else { return }
        continuation.yield(.failed)
    }
}
