import CassiniCore
import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Android's NativeBudgetTest, on Swift tasks: one holder of the native budget at a time, served in order, and a
/// waiter that is cancelled takes nothing. iOS has no plain-thread `acquire` (native work runs on the inference thread
/// a job hands it to), so the interrupt cases are the task's cancellation.
@Suite struct NativeBudgetTests {
    /// Waits, up to 30 s by the clock (E1), until `budget` has `count` waiters: under load a task can take far longer
    /// than any fixed sleep to reach its wait.
    private func waiters(_ budget: NativeBudget, _ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while budget.waiterCount != count {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(budget.waiterCount) waiter(s), expected \(count)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // ports: NativeBudgetTest#acquireAndReleaseOnAPlainThread
    @Test func acquireAndRelease() async throws {
        let budget = NativeBudget()
        try await budget.acquire()
        #expect(budget.isHeld)
        budget.release()
        #expect(!budget.isHeld)
        try await budget.acquire()
        budget.release()
        #expect(!budget.isHeld)
    }

    // ports: NativeBudgetTest#holdingReleasesWhenTheBlockThrows
    @Test func holdingReleasesWhenTheBlockThrows() async {
        struct NativeLoadFailed: Error {}
        let budget = NativeBudget()
        await #expect(throws: NativeLoadFailed.self) { try await budget.withBudget { throw NativeLoadFailed() } }
        #expect(!budget.isHeld)
    }

    // ports: NativeBudgetTest#anInterruptWhileWaitingEndsInCancelledAndKeepsTheFlag
    @Test func aCancelWhileWaitingEndsTheWaitAndTakesNothing() async throws {
        let budget = NativeBudget()
        try await budget.acquire()
        let waiter = Task { try await budget.acquire() }
        // Cancelled once it waits: a cancel before that takes the already-cancelled path (the next test).
        try await waiters(budget, 1)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        budget.release()
        #expect(!budget.isHeld, "the cancelled waiter was not handed the budget")
    }

    // ports: NativeBudgetTest#anAlreadyInterruptedThreadDoesNotTakeAFreeBudget
    @Test func anAlreadyCancelledTaskDoesNotTakeAFreeBudget() async {
        let budget = NativeBudget()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await budget.acquire()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!budget.isHeld)
    }

    // ports: NativeBudgetTest#waitersAreServedOneAtATime
    @Test func waitersAreServedOneAtATime() async throws {
        let budget = NativeBudget()
        let order = Mutex<[Int]>([])
        try await budget.acquire()
        let first = Task { try await budget.withBudget { order.withLock { $0.append(1) } } }
        try await waiters(budget, 1)
        let second = Task { try await budget.withBudget { order.withLock { $0.append(2) } } }
        try await waiters(budget, 2)
        #expect(order.withLock { $0 }.isEmpty)
        budget.release()
        try await first.value
        try await second.value
        #expect(order.withLock { $0 } == [1, 2])
        #expect(!budget.isHeld)
    }
}

/// Android's VoiceprintDimensionTest: the prints a job keeps have the pinned length, so a wrong model file never
/// reaches matching. The native CAM++ model cannot run in a host test; the guard runs over made-up prints.
@Suite struct VoiceprintDimensionTests {
    // ports: VoiceprintDimensionTest#theCatalogueDimensionIsTheAdaptersDimension
    @Test func theCatalogueDimensionIsTheAdaptersDimension() {
        #expect(ModelCatalog.voiceprintDim == VoiceprintModel.dimension)
        #expect(ModelCatalog.voiceprintModel.sha256 == VoiceprintModel.sha256)
    }

    // ports: VoiceprintDimensionTest#printsOfTheDocumentedLengthPassThrough
    @Test func printsOfTheDocumentedLengthPassThrough() throws {
        let prints = ["spk_0": Voiceprint(vector: [Float](repeating: 1 / 512, count: 512), seconds: 1)]
        #expect(try CheckedPrints.check(prints) == prints)
    }

    // ports: VoiceprintDimensionTest#aPrintOfAnotherLengthIsRefused
    @Test func aPrintOfAnotherLengthIsRefused() {
        // ERes2Net, the retired model, produced 192 values: a wrong model file must not reach matching.
        #expect(throws: CheckedPrints.WrongDimension(speaker: "spk_0", count: 192)) {
            try CheckedPrints.check(["spk_0": Voiceprint(vector: [Float](repeating: 0, count: 192), seconds: 1)])
        }
        #expect(CheckedPrints.WrongDimension(speaker: "spk_0", count: 192).description
            == "Voiceprint of spk_0 has 192 values, expected 512")
    }
}

/// `WindowSpeakers` on its own: its best-effort rule and the memory it asks for before the diarizer loads.
@Suite struct WindowSpeakersTests {
    private let chunk = PcmAudio([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    private let words = Transcript([Word("", 100, 400, "ciao")])

    @Test func belowTheDiarizersMemoryEveryWordIsOneVoice() throws {
        let failed = Mutex(0)
        let engines = FakeSpeakerEngines { _, duration in [DiarizerTurn(0, duration, 3)] }
        let speakers = try WindowSpeakers(engines: engines, clips: MemoryClips(), prefix: "P_",
                                          availableMemory: { SpeakerMemory.beforeDiarizerBytes - 1 },
                                          onFailure: { failed.withLock { $0 += 1 } })
        #expect(try speakers.window(chunk, startMs: 0, words: words).words.map(\.speaker) == ["P_1"])
        #expect(engines.opened.isEmpty, "the diarizer never loads")
        #expect(speakers.failed && failed.withLock { $0 } == 1)
        _ = try speakers.window(chunk, startMs: 1000, words: words)
        #expect(failed.withLock { $0 } == 1, "the failure is reported once")
        #expect(speakers.checkpoint().failed)
    }

    @Test func aWindowGivesItsWordsTheSlotsIds() throws {
        let engines = FakeSpeakerEngines { _, duration in [DiarizerTurn(0, duration, 3)] }
        let speakers = try WindowSpeakers(engines: engines, clips: nil, prefix: "P_",
                                          availableMemory: { SpeakerMemory.beforeDiarizerBytes })
        #expect(try speakers.window(chunk, startMs: 0, words: words).words.map(\.speaker) == ["P_4"])
        #expect(speakers.turns == [DiarizerTurn(0, 1000, 3)])
        #expect(speakers.checkpoint().clipSamples == 0, "no clips without the voiceprint model")
        speakers.close()
        #expect(speakers.turns == [DiarizerTurn(0, 1000, 3)], "the turns stay once the diarizer is released")
        // A window where nobody speaks is one voice.
        let silent = try WindowSpeakers(engines: FakeSpeakerEngines { _, _ in [] }, clips: nil, prefix: "Q_")
        #expect(try silent.window(chunk, startMs: 0, words: words).words.map(\.speaker) == ["Q_1"])
        #expect(!silent.failed)
    }

    @Test func aCancellationIsNoSpeakerFailure() throws {
        struct Cancelling: SpeakerEngines {
            func openDiarizer(restored: DiarizerState?) throws -> any StreamingDiarizer { throw CancellationError() }
            func prints(_ audio: any PcmSource, windows: [String: [PrintWindow]],
                        active: () throws -> Void) throws -> [String: Voiceprint] { [:] }
            func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value { try body() }
        }
        let speakers = try WindowSpeakers(engines: Cancelling(), clips: nil)
        #expect(throws: CancellationError.self) { try speakers.window(chunk, startMs: 0, words: words) }
        #expect(!speakers.failed)
    }

    @Test func theMemoryRuleIsTheSystemsWhenItTells() {
        #expect(SpeakerMemory.allows(availableBytes: nil, SpeakerMemory.beforeDiarizerBytes))
        #expect(SpeakerMemory.allows(availableBytes: 0, SpeakerMemory.beforeDiarizerBytes), "the simulator reports 0")
        #expect(!SpeakerMemory.allows(availableBytes: (400 << 20) - 1, SpeakerMemory.beforeDiarizerBytes))
        #expect(SpeakerMemory.allows(availableBytes: 200 << 20, SpeakerMemory.beforePrintsBytes))
    }

    @Test func aFreshPrefixFitsTheWordBodyBudget() {
        let id = WindowSpeakers.freshPrefix() + "8"
        #expect(id.count <= 40, "TranscriptBudget counts 40 characters per speaker id")
        #expect(WindowSpeakers.freshPrefix() != WindowSpeakers.freshPrefix())
    }
}
