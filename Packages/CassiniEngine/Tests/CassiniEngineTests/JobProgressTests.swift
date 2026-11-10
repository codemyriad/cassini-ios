import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniNotebook

@MainActor @Suite struct JobProgressTests {
    private final class Uptime: Sendable {
        let now = Mutex<Int64>(0)
        func advance(_ ms: Int64) { now.withLock { $0 += ms } }
        var value: Int64 { now.withLock { $0 } }
    }

    private final class Battery: BatteryMonitoring {
        func reading() -> (percent: Int, charging: Bool)? { (64, true) }
    }

    @Test func theRowsFollowTheCardAndTheFinalizationIsMeasured() {
        let uptime = Uptime()
        var finalization: Int64?
        let progress = JobProgress(battery: Battery(), uptimeMs: { uptime.value }, onFinalization: { finalization = $0 })
        let id = UUID(), other = UUID()
        #expect(progress.phase(for: id) == nil)
        #expect(progress.processingPhase(for: id) == nil)
        progress.begin(id, finalizationMs: nil)
        progress.apply(.started(JobStart(totalMs: 10_000, speakers: false, prints: false)))
        progress.apply(.windowDone(doneMs: 5_000, totalMs: 10_000, words: []))
        #expect(progress.fraction == 0, "the numbers wait for the next tick")
        uptime.advance(1_000)
        progress.refresh()
        #expect(progress.fraction == 0.5)
        #expect(progress.processingPhase(for: id) == .transcribing)
        #expect(progress.fraction(for: id) == 0.5)
        #expect(progress.fraction(for: other) == nil && progress.processingPhase(for: other) == nil)
        guard case .transcribing(let running, _) = progress.phase(for: id) else { Issue.record("Not running"); return }
        #expect(running.battery == .pluggedIn(percentNow: 64))
        progress.apply(.stageChanged(.saving))
        uptime.advance(700)
        progress.apply(.ended(.done))
        #expect(finalization == 700)
        #expect(progress.fraction == 1)
        progress.end()
        #expect(progress.phase(for: id) == nil)
    }
    @Test func queuedReportsKeepTheirProducerTimesForThePaceEstimate() {
        let uptime = Uptime()
        let progress = JobProgress(uptimeMs: { uptime.value })
        progress.begin(UUID(), finalizationMs: nil)
        // All events arrive after the producer has advanced to its final virtual instant.
        uptime.advance(3_600)
        progress.apply(.started(JobStart(totalMs: 600_000, speakers: false, prints: false)), receivedAt: 0)
        progress.apply(.windowDone(doneMs: 60_000, totalMs: 600_000, words: []), receivedAt: 1_200)
        progress.apply(.windowDone(doneMs: 90_000, totalMs: 600_000, words: []), receivedAt: 2_400)
        progress.apply(.windowDone(doneMs: 120_000, totalMs: 600_000, words: []), receivedAt: 3_600)
        progress.refresh()
        guard case .transcribing(let running, _) = progress.phase else { Issue.record("Not transcribing"); return }
        #expect(running.percent == 20)
        if case .range = running.timeLeft {} else { Issue.record("queued virtual reports lost their distinct pace samples: \(running.timeLeft)") }
    }

}
