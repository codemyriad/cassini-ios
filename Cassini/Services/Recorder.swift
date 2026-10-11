import AVFoundation
import Observation
import CassiniNotebook

@MainActor @Observable final class Recorder: NSObject, AVAudioRecorderDelegate {
    private(set) var noteID: UUID?
    private(set) var elapsed: Double = 0
    private(set) var isPaused = false
    private(set) var levels: [Float] = Array(repeating: 0.05, count: 64)
    var notice: String?
    var onUnexpectedStop: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var isActive: Bool { noteID != nil }

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor in self?.pause(); self?.notice = "Recording paused by another app. Resume when you’re ready." }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause(); self?.notice = "Your audio input disconnected. Check your microphone, then resume." }
            }
        })
    }

    func start(note: Note, url: URL) async throws {
        guard !isActive else { throw AudioError.busy }
        guard await AVAudioApplication.requestRecordPermission() else { throw AudioError.microphoneDenied }
        try Self.checkStorage(at: url.deletingLastPathComponent())
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            guard session.isInputAvailable else { throw AudioError.noInput }
            try session.setActive(true)
            // PCM in CAF remains readable if the process dies before stop() can finalize it.
            // Compress only after the source and its metadata are durably saved.
            let capture = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            capture.isMeteringEnabled = true; capture.delegate = self
            guard capture.record() else { throw AudioError.startFailed }
            recorder = capture; noteID = note.id; elapsed = 0; isPaused = false; notice = nil
            levels = Array(repeating: 0.05, count: 64)
            let meterTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer = meterTimer
            RunLoop.main.add(meterTimer, forMode: .common)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw (error as? AudioError) ?? .startFailed
        }
    }
    static func checkStorage(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < 200_000_000 { throw AudioError.storageLow }
    }
    private func tick() {
        guard let recorder, !isPaused else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        levels.append(max(0.04, min(1, pow(10, recorder.averagePower(forChannel: 0) / 35))))
        levels.removeFirst(max(0, levels.count - 64))
        if Int(elapsed * 10) % 100 == 0 {
            do { try Self.checkStorage(at: recorder.url.deletingLastPathComponent()) }
            catch { notice = error.localizedDescription; onUnexpectedStop?() }
        }
    }
    func pause() { guard isActive else { return }; recorder?.pause(); isPaused = true }
    func resume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard recorder?.record() == true else { throw AudioError.startFailed }
            isPaused = false; notice = nil
        } catch { notice = error.localizedDescription }
    }
    func finish() -> Double {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop(); timer?.invalidate(); timer = nil; recorder = nil; noteID = nil; isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            notice = "Recording stopped because of an audio error. Your saved audio has been kept."; onUnexpectedStop?()
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == identity, isActive else { return }
            notice = "Recording stopped. Your saved audio has been kept."; onUnexpectedStop?()
        }
    }
}
