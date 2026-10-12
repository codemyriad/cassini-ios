#if DEBUG
import AVFoundation
import CassiniEngine
import CassiniNotebook

/// A microphone that plays back scripted levels and writes a second-long tone per second captured, so a recording
/// works where the simulator has no input.
@MainActor public final class FakeCapture: AudioCapture {
    public let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let levels: [Float]
    private let frozenElapsed: TimeInterval?
    private var url: URL?
    private var startedAt: Date?
    private var banked: TimeInterval = 0
    private var ticker: Task<Void, Never>?
    public private(set) var isPaused = false
    public var startError: (any Error)?

    /// `levels` repeat while capturing; with `frozenElapsed` the elapsed time stands still at that value.
    public init(levels: [Float] = [0.2, 0.45, 0.7, 0.35, 0.9, 0.5, 0.25, 0.6], frozenElapsed: TimeInterval? = nil) {
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        self.levels = levels.isEmpty ? [0.5] : levels
        self.frozenElapsed = frozenElapsed
    }

    public var elapsed: TimeInterval {
        if let frozenElapsed { return frozenElapsed }
        return banked + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    public var fileBytes: Int64 { Int64(elapsed * 96_000) }

    public func start(url: URL) async throws -> CaptureFormat {
        if let startError { throw startError }
        self.url = url
        banked = 0; startedAt = Date(); isPaused = false
        tick()
        return .pcm48kMono
    }

    public func pause() {
        guard !isPaused, let startedAt else { return }
        banked += Date().timeIntervalSince(startedAt)
        self.startedAt = nil; isPaused = true
        ticker?.cancel()
    }

    public func resume() throws {
        guard isPaused else { return }
        startedAt = Date(); isPaused = false
        tick()
    }

    public func stop() async throws -> CaptureResult {
        let duration = max(1, elapsed.rounded(.up))
        ticker?.cancel(); startedAt = nil
        if let url { try Self.writeTone(to: url, seconds: duration) }
        url = nil
        return CaptureResult(duration: duration)
    }

    /// Sends a capture event as the system would.
    public func send(_ event: CaptureEvent) { continuation.yield(event) }

    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self, levels, continuation] in
            var index = 0
            while !Task.isCancelled, self != nil {
                continuation.yield(.level(levels[index % levels.count]))
                index += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    nonisolated private static func writeTone(to url: URL, seconds: TimeInterval) throws {
        let rate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(rate)
        for index in 0..<Int(rate) { samples[index] = Float(sin(Double(index) * 2 * .pi * 220 / rate)) * 0.2 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<Int(seconds) { try file.write(from: buffer) }
    }
}
#endif
