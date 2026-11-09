import Foundation

/// Turns the `JobEvent`s of one job run into the `JobPhase` the Note screen shows. Use one tracker per run: it owns that
/// run's `TranscriptionProgress` and a fresh `BatteryProjection`, so a resumed job measures battery use from its own
/// start.
///
/// The tracker has no timer of its own. Its driver applies each event with the time it arrived and calls `tick(at:)`
/// once a second while `isTicking`, and at once after anything the user changed. Times are monotonic milliseconds; the
/// elapsed time of a run is the checkpoint's elapsed time plus the time since `JobEvent.started`.
///
/// Rules (Android's `ProgressTracker`, with the iOS stepper):
/// - The step is monotonic, starting at Reading on every run; a stage below it is dropped, and the headline never shows
///   a step below the stepper. Within a step a stage shorter than 400 ms is not shown.
/// - The percent never goes back and is at most 99 until `JobOutcome.done`. When the speaker step will run, the words
///   fill 0–85 % and the speakers 85–99 %; otherwise the words fill the bar. A run without a words step (Identify
///   speakers) fills the bar with the speaker step alone, and its Processed stat is the analysed audio.
/// - Time left is Calculating until 3 results since this run began and while the total is unknown, then the rounded
///   range plus `finalizationMs`. In the speaker step it is measured from that step's own progress. Finishing when only
///   saving is left.
/// - Battery: hidden without a reading, Plugged in while charging, Measuring until 120 s and a 0.5 % drop, else the
///   projection at the finish. Read every 10 s.
/// - Draft: every word so far, with the speaker ids the job gave them; words ending after the job's tentative point may
///   still change until the words are final. Naming is open until `namingClosed` (`DraftView` applies the names).
public struct ProgressTracker: Sendable {
    public typealias BatterySource = @Sendable (_ elapsedMs: Int64) -> BatteryProjection.Reading?

    /// The percent where the speaker step begins when it runs.
    static let wordsShare = 85
    static let cap = 99
    static let batteryIntervalMs: Int64 = 10_000
    /// Draft words this close to the end of the finalized audio may still change.
    public static let settleMs: Int64 = 2_000
    /// The speaker step needs this share done and this long before its time left is estimated.
    static let speakerEstimateFraction = 0.05
    static let speakerEstimateMs: Int64 = 3_000

    public private(set) var phase: JobPhase = .starting
    /// The outcome of `JobEvent.ended`, once it came.
    public private(set) var outcome: JobOutcome?

    private let finalizationMs: Int64
    private let battery: BatterySource
    private var run: Run?
    private var stopping = false

    public init(finalizationMs: Int64 = 0, battery: @escaping BatterySource = { _ in nil }) {
        self.finalizationMs = max(0, finalizationMs)
        self.battery = battery
    }

    /// Whether the driver should call `tick(at:)` once a second.
    public var isTicking: Bool { run != nil && !stopping && outcome == nil }

    /// Applies one event that arrived at `nowMs`.
    public mutating func apply(_ event: JobEvent, at nowMs: Int64) {
        switch event {
        case .started(let start):
            begin(start, at: nowMs)
        case .stopping:
            stopping = true
            phase = .stopping
        case .ended(let ended):
            outcome = ended
            if ended == .done { publish(at: nowMs, done: true) }
        case .waitingForPrevious:
            if run == nil, !stopping { phase = .waitingForPrevious }
        case .downloading(let progress):
            if run == nil {
                if !stopping { phase = .downloading(progress) }
            } else {
                run?.download = progress
                // Download/check boundaries drive model readiness followers; do not hide them until the next tick.
                if isTicking { publish(at: nowMs, done: false) }
            }
        default:
            guard var current = run else { return }
            let previousDownload = current.download
            on(event, &current, at: nowMs)
            run = current
            if previousDownload != current.download, isTicking { publish(at: nowMs, done: false) }
        }
    }

    /// Publishes the running numbers; nothing once the run is stopping or over.
    public mutating func tick(at nowMs: Int64) {
        guard isTicking else { return }
        publish(at: nowMs, done: false)
    }

    // MARK: - Events

    private mutating func begin(_ start: JobStart, at nowMs: Int64) {
        var progress = TranscriptionProgress(totalMs: start.totalMs)
        if let restored = start.restored {
            progress.restore(doneMs: restored.doneMs, totalMs: restored.totalMs, words: restored.words.count,
                             elapsedMs: restored.elapsedMs)
        }
        var state = Run(progress: progress, startedAt: nowMs, checkpointElapsedMs: start.restored?.elapsedMs ?? 0)
        state.lowMemory = start.lowMemory
        state.speakers = start.speakers
        state.words = start.restored?.words ?? []
        state.wordsRan = start.restored != nil
        state.tentativeFromMs = (start.restored?.doneMs ?? 0) - Self.settleMs
        run = state
        publish(at: nowMs, done: false)
    }

    private func on(_ event: JobEvent, _ run: inout Run, at nowMs: Int64) {
        let elapsed = run.elapsed(at: nowMs)
        switch event {
        case .stageChanged(let stage, let startMs, let endMs):
            run.download = nil
            switch stage {
            case .speakers:
                run.speakersEndMs = max(run.speakersEndMs, endMs)
                if run.speakersStartedAt == nil { run.speakersStartedAt = elapsed }
            case .matching:
                // Matching begins once every bit of audio is analysed.
                run.speakersEndMs = .max
            default:
                break
            }
            self.stage(&run, stage, startMs, endMs, elapsed)
        case .reading(let readMs, let totalMs):
            if let totalMs { run.progress.total(totalMs) }
            self.stage(&run, .reading, 0, readMs, elapsed)
        case .windowDone(let doneMs, let totalMs, let words):
            run.download = nil
            run.wordsRan = true
            run.progress.complete(done: doneMs, total: totalMs, words: words.count, at: elapsed)
            run.words = words
            run.tentativeFromMs = doneMs - Self.settleMs
        case .draft(let words, let tentativeFromMs):
            run.words = words
            run.tentativeFromMs = tentativeFromMs
        case .speakersUnavailable:
            run.speakers = false
        case .namingClosed(let matching):
            run.decoded = true
            run.speakers = matching
        default:
            break
        }
    }

    /// Stages below the stepper are dropped (a Reading between two results): the stepper and its top stage only move
    /// forward.
    private func stage(_ run: inout Run, _ stage: TranscriptionStage, _ startMs: Int64, _ endMs: Int64, _ elapsed: Int64) {
        let step = JobStep.of(stage)
        if step == .speakers { run.speakersEntered = true }
        if step < .speakers { run.wordsRan = true }
        guard step >= run.step else { return }
        run.progress.stage(stage, at: elapsed, startMs: startMs, endMs: endMs)
        run.step = step
        run.top = Shown(stage: stage, startMs: startMs, endMs: endMs)
    }

    // MARK: - Publishing

    private mutating func publish(at nowMs: Int64, done: Bool) {
        guard var current = run, !stopping || done else { return }
        let progress = progress(&current, at: nowMs, done: done)
        let decoded = current.decoded || done
        let draft = DraftState(words: current.words, tentativeFromMs: decoded ? .max : current.tentativeFromMs,
                               namingOpen: !decoded)
        run = current
        phase = .transcribing(progress, draft)
    }

    private func progress(_ run: inout Run, at nowMs: Int64, done: Bool) -> RunningProgress {
        let elapsed = run.elapsed(at: nowMs)
        let snapshot = run.progress.snapshot(at: elapsed)
        let shown = JobStep.of(snapshot.stage) < run.step
            ? run.top : Shown(stage: snapshot.stage, startMs: snapshot.startMs, endMs: snapshot.endMs)
        let speakersAhead = run.speakers && !done
        if let percent = percent(run, snapshot) { run.percent = max(run.percent ?? 0, percent) }
        return RunningProgress(
            headline: Self.headline(shown.stage),
            rangeStartMs: shown.startMs, rangeEndMs: shown.endMs,
            percent: done ? 100 : run.percent.map { min($0, Self.cap) },
            step: done ? .saving : run.step,
            speakersSkipped: !run.speakersEntered && (run.step == .saving || done || !run.speakers),
            timeLeft: done ? .finishing : timeLeft(run, snapshot, elapsed: elapsed, speakersAhead: speakersAhead),
            doneMs: run.speakersOnly ? min(max(run.speakersEndMs, 0), snapshot.totalMs) : snapshot.doneMs,
            totalMs: snapshot.totalMs,
            battery: batteryLine(&run, snapshot, elapsed: elapsed, speakersAhead: speakersAhead),
            words: snapshot.words, download: run.download, lowMemory: run.lowMemory)
    }

    /// The bar: the words' share of transcribed audio, then the speaker step's share of analysed audio.
    private func percent(_ run: Run, _ snapshot: TranscriptionProgress.Snapshot) -> Int? {
        guard let words = snapshot.percent else { return nil }
        guard run.speakers || run.speakersEntered else { return words }
        let wordsPart = words * Self.wordsShare / 100
        guard run.step >= .speakers, snapshot.totalMs > 0 else { return wordsPart }
        let analysed = min(max(run.speakersEndMs, 0), snapshot.totalMs)
        let start = run.speakersOnly ? 0 : Self.wordsShare
        return start + Int(analysed * Int64(Self.cap - start) / snapshot.totalMs)
    }

    private func timeLeft(_ run: Run, _ snapshot: TranscriptionProgress.Snapshot, elapsed: Int64,
                          speakersAhead: Bool) -> TimeLeft {
        if run.step >= .speakers, run.step < .saving, run.speakers {
            guard let left = speakerRemainingMs(run, snapshot, elapsed: elapsed) else { return .calculating }
            return range(low: left * 3 / 4, high: left * 5 / 4)
        }
        guard let remaining = snapshot.remainingMs else { return .calculating }
        if remaining <= 0 { return speakersAhead && run.step < .saving ? .calculating : .finishing }
        return range(low: snapshot.remainingLowMs ?? remaining, high: snapshot.remainingHighMs ?? remaining)
    }

    private func range(low: Int64, high: Int64) -> TimeLeft {
        .range(lowMs: TranscriptionProgress.roundedRemaining(low + finalizationMs),
               highMs: TranscriptionProgress.roundedRemaining(high + finalizationMs))
    }

    /// What is left of the speaker step, extrapolated from its own pace.
    private func speakerRemainingMs(_ run: Run, _ snapshot: TranscriptionProgress.Snapshot, elapsed: Int64) -> Int64? {
        guard let startedAt = run.speakersStartedAt, snapshot.totalMs > 0 else { return nil }
        let fraction = Double(min(run.speakersEndMs, snapshot.totalMs)) / Double(snapshot.totalMs)
        let spent = elapsed - startedAt
        guard fraction >= Self.speakerEstimateFraction, spent >= Self.speakerEstimateMs else { return nil }
        return max(Int64(Double(spent) * (1 - fraction) / fraction), TranscriptionProgress.minimumRemainingMs)
    }

    private func batteryLine(_ run: inout Run, _ snapshot: TranscriptionProgress.Snapshot, elapsed: Int64,
                             speakersAhead: Bool) -> BatteryLine {
        if run.batteryReadAt.map({ elapsed - $0 >= Self.batteryIntervalMs }) ?? true {
            run.batteryReadAt = elapsed
            run.reading = battery(elapsed)
        }
        guard let reading = run.reading else { return .unavailable }
        let left: Int64? = if run.step >= .speakers, run.speakers {
            speakerRemainingMs(run, snapshot, elapsed: elapsed).map { $0 * 5 / 4 + finalizationMs }
        } else if let remaining = snapshot.remainingMs, remaining > 0 {
            (snapshot.remainingHighMs ?? remaining) + finalizationMs
        } else {
            nil
        }
        let estimate = run.projection.sample(reading, remainingMs: left)
        guard let now = estimate.percentNow else { return .unavailable }
        if estimate.charging { return .pluggedIn(percentNow: now) }
        if let after = estimate.percentAfter { return .projected(percentNow: now, percentAtFinish: after) }
        return .measuring(percentNow: now)
    }

    static func headline(_ stage: TranscriptionStage) -> ProgressHeadline {
        switch stage {
        case .reading: .readingAudio
        case .preparing: .preparing
        case .words: .findingWords
        case .speakers: .findingSpeakers
        case .matching: .matchingVoices
        case .saving: .saving
        }
    }

    /// A stage with its audio range, as the headline shows it.
    private struct Shown: Sendable {
        var stage: TranscriptionStage
        var startMs: Int64
        var endMs: Int64
    }

    /// One run's numbers.
    private struct Run: Sendable {
        var progress: TranscriptionProgress
        let startedAt: Int64
        let checkpointElapsedMs: Int64
        var projection = BatteryProjection()
        /// The speaker step will run (from `JobStart`, then `speakersUnavailable` and `namingClosed`).
        var speakers = false
        /// The speaker step began.
        var speakersEntered = false
        /// The run has a words step, or resumed from words a checkpoint holds.
        var wordsRan = false
        var speakersStartedAt: Int64?
        var speakersEndMs: Int64 = 0
        var words: [DraftWord] = []
        var tentativeFromMs: Int64 = 0
        var step = JobStep.reading
        var top = Shown(stage: .reading, startMs: 0, endMs: 0)
        var percent: Int?
        /// The words are final.
        var decoded = false
        var download: DownloadProgress?
        var lowMemory = false
        var batteryReadAt: Int64?
        var reading: BatteryProjection.Reading?

        init(progress: TranscriptionProgress, startedAt: Int64, checkpointElapsedMs: Int64) {
            self.progress = progress; self.startedAt = startedAt; self.checkpointElapsedMs = checkpointElapsedMs
        }

        func elapsed(at nowMs: Int64) -> Int64 { checkpointElapsedMs + (nowMs - startedAt) }

        /// Identify speakers: the speaker step is the whole job.
        var speakersOnly: Bool { speakersEntered && !wordsRan }
    }
}
