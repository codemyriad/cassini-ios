import AVFoundation
import UIKit
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// What the adapter uses of `AVAudioRecorder`, so a test can give it a recorder whose `record()` fails.
protocol CaptureRecorder: AnyObject {
    var delegate: (any AVAudioRecorderDelegate)? { get set }
    var isMeteringEnabled: Bool { get set }
    var currentTime: TimeInterval { get }
    var url: URL { get }
    func record() -> Bool
    func pause()
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: CaptureRecorder {}

/// The shared audio session as the adapter uses it; `live` is the device's.
@MainActor struct CaptureSession {
    var requestPermission: @MainActor () async -> Bool
    /// Sets the category and activates the session; throws `AudioError.noInput` when there is no input to record from.
    var prepare: @MainActor () async throws -> Void
    /// Activates the session as it is set up, to resume.
    var activate: @MainActor () async throws -> Void
    var deactivate: @MainActor () -> Void

    static let live = CaptureSession(
        requestPermission: { await AVAudioApplication.requestRecordPermission() },
        prepare: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            guard session.isInputAvailable else { throw AudioError.noInput }
            try await AudioSession.activate()
            // A simulator on a Mac without a microphone reports an input but has no channels; recording from it ends
            // the app inside Core Audio.
            guard session.inputNumberOfChannels > 0 else { throw AudioError.noInput }
        },
        activate: { try await AudioSession.activate() },
        deactivate: { AudioSession.deactivate() })
}

/// The microphone through `AVAudioRecorder`, writing 48 kHz 16-bit mono PCM into CAF. The session does not mix with
/// other apps, so a call interrupts (and pauses) the recording.
@MainActor final class AVCaptureAdapter: NSObject, AudioCapture, AVAudioRecorderDelegate {
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let session: CaptureSession
    private let previewRun: RecordingPreview.Run?
    private(set) var preview: RecordingPreview?
    private var nextPreviewWake: UInt64 = 0
    private let makeRecorder: @MainActor (URL) throws -> any CaptureRecorder
    private(set) var recordedAt: Date?
    private var recorder: (any CaptureRecorder)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isPaused = false

    init(session: CaptureSession = .live,
         previewRun: RecordingPreview.Run? = nil,
         makeRecorder: @escaping @MainActor (URL) throws -> any CaptureRecorder = AVCaptureAdapter.pcmRecorder) {
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        self.session = session
        self.previewRun = previewRun
        self.makeRecorder = makeRecorder
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
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preview?.cancel() }
        })
        // The app is being closed: stopping writes the CAF header now, so recovery finds a clean file at next launch.
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForTermination() }
        })
    }

    isolated deinit {
        preview?.cancel()
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        continuation.finish()
    }

    var livePCMURL: URL? { recorder?.url }

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    var fileBytes: Int64 {
        guard let url = recorder?.url else { return 0 }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func start(url: URL) async throws -> CaptureFormat {
        guard recorder == nil else { throw AudioError.busy }
        guard await session.requestPermission() else { throw AudioError.microphoneDenied }
        do {
            try await session.prepare()
            let capture = try makeRecorder(url)
            capture.isMeteringEnabled = true; capture.delegate = self
            guard capture.record() else {
                // A record() that fails can leave the recorder's audio queue running, and its input callback reads the
                // recorder: released unstopped, the recorder ended the app (EXC_BAD_ACCESS in
                // AudioRecorderAQInputCallback, seen when record() gave up after about 30 s on a busy simulator).
                capture.delegate = nil; capture.stop()
                throw AudioError.startFailed
            }
            // record() can spend time preparing hardware; anchor to the actual audio position after it succeeds.
            recordedAt = Date().addingTimeInterval(-max(0, capture.currentTime))
            recorder = capture; isPaused = false
            preview?.cancel()
            preview = previewRun.map { RecordingPreview(url: url, run: $0) }
            nextPreviewWake = 0
            startMetering()
            return .pcm48kMono
        } catch {
            session.deactivate()
            throw (error as? AudioError) ?? .startFailed
        }
    }

    /// The device's recorder. PCM in CAF stays readable if the process dies before stop() can finalize it.
    static func pcmRecorder(url: URL) throws -> any CaptureRecorder {
        try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    }

    func pause() {
        guard let recorder, !isPaused else { return }
        recorder.pause(); isPaused = true
        timer?.invalidate(); timer = nil
    }

    /// Resumes once the session is active again, off the main thread (`AudioSession`); when another app still holds
    /// the audio, the capture stays paused as after an interruption.
    func resume() throws {
        guard recorder != nil else { return }
        isPaused = false
        Task { [weak self] in
            let error: (any Error)?
            do { try await self?.session.activate(); error = nil } catch let failure { error = failure }
            guard let self, let recorder = self.recorder, !self.isPaused else { return }
            if error != nil || !recorder.record() { self.pauseAndReport(.interrupted) }
            else { self.startMetering() }
        }
    }

    func stop() async throws -> CaptureResult {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop(); timer?.invalidate(); timer = nil; recorder = nil; isPaused = false
        preview?.finish()
        session.deactivate()
        return CaptureResult(duration: duration)
    }

    /// Stops at once without reporting a failure: the delegate's finish callback is not for the recorder in use.
    private func stopForTermination() {
        guard let capture = recorder else { return }
        recorder = nil
        timer?.invalidate(); timer = nil
        capture.stop()
        preview?.cancel()
    }

    private func startMetering() {
        timer?.invalidate()
        // Forty samples/sec preserve short peaks; only the visible Canvas runs at display cadence.
        let meterTimer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        meterTimer.tolerance = 0.005
        timer = meterTimer
        RunLoop.main.add(meterTimer, forMode: .common)
    }

    private func tick() {
        guard let recorder, !isPaused else { return }
        recorder.updateMeters()
        if let preview {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= nextPreviewWake {
                nextPreviewWake = now + 100_000_000
                preview.audioAvailable()
            }
        }
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
        preview?.finish()
        continuation.yield(.failed)
    }
}
