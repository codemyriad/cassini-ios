import Testing
@testable import CassiniEngine

@MainActor @Suite struct StartupTests {
    struct Failure: Error {}

    // ports: AppGraphTest#theStartupStepsRunInTheirOrderRecoverBeforeReconcile
    @Test func hooksRunInTheirStepOrderWhateverTheRegistrationOrder() async {
        let startup = Startup()
        var log: [String] = []
        startup.register(.sweep) { log.append("sweep") }
        startup.register(.purge) { log.append("purge") }
        startup.register(.reconcile) { log.append("reconcile") }
        startup.register(.recover) { log.append("recover") }
        startup.register(.recover) { log.append("recover 2") }
        startup.register(.voiceLinks) { log.append("voiceLinks") }
        startup.register(.load) { log.append("load") }
        var steps: [StartupStep] = []
        let report = await startup.run { steps.append($0) }
        #expect(log == ["load", "recover", "recover 2", "reconcile", "voiceLinks", "purge", "sweep"])
        #expect(steps == StartupStep.allCases)
        #expect(report.ran == StartupStep.allCases)
        #expect(report.failed.isEmpty)
        #expect(startup.isReady)
    }

    @Test func aFailingHookIsReportedAndTheNextStepsStillRun() async {
        let startup = Startup()
        var purged = false
        startup.register(.recover) { throw Failure() }
        startup.register(.purge) { purged = true }
        let report = await startup.run()
        #expect(purged)
        #expect(report.failed.keys.sorted() == [.recover])
    }

    @Test func waitersResumeWhenEveryStepHasRun() async {
        let startup = Startup()
        var release: CheckedContinuation<Void, Never>?
        startup.register(.load) { await withCheckedContinuation { release = $0 } }
        let running = Task { await startup.run() }
        while release == nil { await Task.yield() }

        let waiter = Task { await startup.ready() }
        let second = Task { await startup.run() }
        while startup.waiters.count < 2 { await Task.yield() }
        #expect(!startup.isReady)

        release?.resume()
        let report = await running.value
        #expect(await waiter.value == report)
        #expect(await second.value == report, "a run while one runs waits for it")
        #expect(startup.waiters.isEmpty)
        #expect(await startup.run() == report, "a second run does nothing")
    }
}
