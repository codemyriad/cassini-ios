import Testing
import CassiniEngine

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
        async let waited = startup.ready()
        let report = await startup.run()
        #expect(await waited == report)
        #expect(await startup.run() == report, "a second run does nothing")
    }
}
