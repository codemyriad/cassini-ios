import Foundation
import Observation
import Synchronization
import CassiniNotebook

/// The device's battery, read on the main actor.
@MainActor public protocol BatteryMonitoring: AnyObject {
    /// 0 to 100 and whether it is charging; nil when there is no reading (the simulator, say).
    func reading() -> (percent: Int, charging: Bool)?
}

/// The running job's progress card, as the Note screen and the library rows see it. The queue's driver calls `begin`
/// when a job starts, `apply` for each of its events in order, and `end` when it is over; in between this ticks the
/// job's `ProgressTracker` once a second.
@MainActor @Observable public final class JobProgress {
    public private(set) var noteID: UUID?
    public private(set) var phase: JobPhase = .starting

    @ObservationIgnored private var tracker = ProgressTracker()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let battery: (any BatteryMonitoring)?
    @ObservationIgnored private let latestReading = BatteryBox()
    @ObservationIgnored private let uptimeMs: @Sendable () -> Int64
    @ObservationIgnored private var finalizingSince: Int64?
    /// Called with the time from the end of the speaker analysis to the saved note, for the next estimate.
    @ObservationIgnored public var onFinalization: ((Int64) -> Void)?
    /// Called after every publish, at events and ticks alike.
    @ObservationIgnored public var onPublish: (() -> Void)?

    static let tickInterval = Duration.seconds(1)

    public init(battery: (any BatteryMonitoring)? = nil,
                uptimeMs: @escaping @Sendable () -> Int64 = TranscriptionJob.uptimeMs) {
        self.battery = battery
        self.uptimeMs = uptimeMs
    }

    /// The progress of `id`'s job while it runs.
    public func phase(for id: UUID) -> JobPhase? { noteID == id ? phase : nil }

    public func begin(_ id: UUID, finalizationMs: Int64?) {
        end()
        noteID = id
        let box = latestReading
        tracker = ProgressTracker(finalizationMs: finalizationMs ?? 0) { elapsed in
            box.value.map { BatteryProjection.Reading(elapsedMs: elapsed, percent: $0.percent, charging: $0.charging) }
        }
        phase = tracker.phase
    }

    public func apply(_ event: JobEvent) {
        guard noteID != nil else { return }
        let now = uptimeMs()
        switch event {
        case .stageChanged(.matching, _, _), .stageChanged(.saving, _, _):
            if finalizingSince == nil { finalizingSince = now }
        case .ended(.done):
            if let since = finalizingSince { onFinalization?(now - since) }
        default:
            break
        }
        if case .started = event { readBattery() }
        tracker.apply(event, at: now)
        publish()
        if tracker.isTicking { startTicking() } else { stopTicking() }
    }

    /// Publishes at once, without waiting for the next tick.
    public func refresh() {
        guard noteID != nil else { return }
        readBattery()
        tracker.tick(at: uptimeMs())
        publish()
    }

    public func end() {
        stopTicking()
        noteID = nil
        finalizingSince = nil
        phase = .starting
    }

    /// What a library row shows for the running job.
    public var processingPhase: ProcessingPhase {
        switch phase {
        case .starting, .waitingForPrevious: return .starting
        case .downloading(let progress): return .downloading(progress.map { Double($0.percent) / 100 })
        case .stopping: return .stopping
        case .transcribing(let progress, _):
            if let download = progress.download {
                let fraction = Double(download.percent) / 100
                return download.part == .speech ? .downloading(fraction) : .preparingSpeakers(fraction)
            }
            switch progress.headline {
            case .starting, .waitingForPrevious, .readingAudio, .preparing, .findingWords: return .transcribing
            case .findingSpeakers: return .identifyingSpeakers
            case .matchingVoices: return .matching
            case .saving: return .saving
            }
        }
    }

    /// The bar of a library row, 0 to 1; nil while unknown.
    public var fraction: Double? {
        guard case .transcribing(let progress, _) = phase, let percent = progress.percent else { return nil }
        return Double(percent) / 100
    }

    private func publish() {
        if phase != tracker.phase { phase = tracker.phase }
        onPublish?()
    }

    private func readBattery() { latestReading.value = battery?.reading() }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}

/// The latest battery reading, written on the main actor and read by the tracker's battery source.
private final class BatteryBox: Sendable {
    private let reading = Mutex<(percent: Int, charging: Bool)?>(nil)
    var value: (percent: Int, charging: Bool)? {
        get { reading.withLock { $0 } }
        set { reading.withLock { $0 = newValue } }
    }
}
