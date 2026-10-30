import AVFoundation
import UIKit
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// The microphone through `AVAudioRecorder`, writing 48 kHz 16-bit mono PCM into CAF. The session does not mix with
/// other apps, so a call interrupts (and pauses) the recording.
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
        // The app is being closed: stopping writes the CAF header now, so recovery finds a clean file at next launch.
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForTermination() }
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
            try await AudioSession.activate()
            // A simulator on a Mac without a microphone reports an input but has no channels; recording from it ends
            // the app inside Core Audio.
            guard session.inputNumberOfChannels > 0 else { throw AudioError.noInput }
            // PCM in CAF stays readable if the process dies before stop() can finalize it.
            let capture = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            capture.isMeteringEnabled = true; capture.delegate = self
            guard capture.record() else {
                // A record() that fails can leave the recorder's audio queue running, and its input callback reads the
                // recorder: released unstopped, the recorder ended the app (EXC_BAD_ACCESS in
                // AudioRecorderAQInputCallback, seen when record() gave up after about 30 s on a busy simulator).
                capture.delegate = nil; capture.stop()
                throw AudioError.startFailed
            }
            recorder = capture; isPaused = false
            let meterTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer = meterTimer
            RunLoop.main.add(meterTimer, forMode: .common)
            return .pcm48kMono
        } catch {
            AudioSession.deactivate()
            throw (error as? AudioError) ?? .startFailed
        }
    }

    func pause() {
        guard let recorder, !isPaused else { return }
        recorder.pause(); isPaused = true
    }

    /// Resumes once the session is active again, off the main thread (`AudioSession`); when another app still holds
    /// the audio, the capture stays paused as after an interruption.
    func resume() throws {
        guard recorder != nil else { return }
        isPaused = false
        Task { [weak self] in
            let error: (any Error)?
            do { try await AudioSession.activate(); error = nil } catch let failure { error = failure }
            guard let self, let recorder = self.recorder, !self.isPaused else { return }
            if error != nil || !recorder.record() { self.pauseAndReport(.interrupted) }
        }
    }

    func stop() async throws -> CaptureResult {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop(); timer?.invalidate(); timer = nil; recorder = nil; isPaused = false
        AudioSession.deactivate()
        return CaptureResult(duration: duration)
    }

    /// Stops at once without reporting a failure: the delegate's finish callback is not for the recorder in use.
    private func stopForTermination() {
        guard let capture = recorder else { return }
        recorder = nil
        timer?.invalidate(); timer = nil
        capture.stop()
    }

    private func tick() {
        guard let recorder, !isPaused else { return }
        recorder.updateMeters()
        continuation.yield(.level(max(0, min(1, pow(10, recorder.averagePower(forChannel: 0) / 35)))))
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
