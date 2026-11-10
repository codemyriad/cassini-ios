import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionJobTests {
    /// The words step honours a stop at the next result, with no stop watch involved: the job tests stop once a result
    /// is in and hold the decode until the watch cancels it (D88), so they no longer reach this boundary, which a stop
    /// asked while a native call runs does. Here the results go to the step directly, in order.
    @Suite struct StopBoundary {
        /// The words step of a run over the scripted 70 s, as the job sets it up for a fresh Apple Speech run.
        struct Step {
            let h: Harness
            let stop = StopSignal()
            let decode: WordsDecode
            let events = EventLog()
            let script = ScriptedTranscriber.seventySeconds

            init() async throws {
                let h = try await Harness()
                self.h = h
                let uptime = FakeUptime(), events = events
                decode = WordsDecode(
                    base: CheckpointState(source: "audio.m4a", signature: CheckpointState.signature(of: h.audioURL),
                                          model: CheckpointState.appleModel(language: "it-IT"), segments: [], doneMs: 0,
                                          totalMs: 70_000, elapsedMs: 0),
                    noteID: h.noteID, resumeDoneMs: 0, language: "it-IT", limits: h.limits, checkpoints: h.checkpoints,
                    stop: stop, events: { event in events.list.withLock { $0.append(event) } }, uptimeMs: { uptime.next() })
            }

            /// Hands the step the results at `indices`, each with its progress, as `ScriptedTranscriber` does.
            func results(_ indices: Range<Int>) {
                for index in indices {
                    decode.handle(.finalized(script[index]))
                    decode.handle(.progress(done: script[index].end, total: 70))
                }
            }
        }

        final class EventLog: Sendable {
            let list = Mutex<[JobEvent]>([])
        }

        @Test func aPauseAskedBeforeAResultIsHonouredAtThatResultWithItsCheckpoint() async throws {
            let step = try await Step()
            let decoding = Task<TranscriptionResult, any Error> { try await holdUntilTheJobCancels(); throw CancellationError() }
            step.decode.attach(decoding)
            step.results(0..<7)
            #expect(step.h.checkpoints.saved.map(\.doneMs) == [30_000])

            step.stop.stop(.pause(.user))
            step.results(7..<9)
            // The result the stop arrived before is kept, and the step ends there: the next one is not taken.
            #expect(step.h.checkpoints.saved.map(\.doneMs) == [30_000, 40_000])
            #expect(step.h.checkpoints.saved.last?.wordsComplete == false)
            #expect(step.h.checkpoints.saved.last?.segments.last == step.script[7])
            #expect(decoding.isCancelled, "the transcriber is cancelled once the stop is honoured")
            decoding.cancel()
            #expect(step.events.list.withLock { $0.contains(.stopping) })
            #expect(step.events.list.withLock { $0.compactMap(\.checkpointed) } == [30_000, 40_000])
            guard case .stopped(.pause(.user)) = step.decode.finish(await decoding.result) else {
                Issue.record("the step ends paused")
                return
            }
        }

        @Test func aCancelAskedBeforeAResultEndsTheStepWithoutACheckpoint() async throws {
            let step = try await Step()
            let decoding = Task<TranscriptionResult, any Error> { try await holdUntilTheJobCancels(); throw CancellationError() }
            step.decode.attach(decoding)
            step.results(0..<9)
            step.stop.stop(.cancel)
            step.results(9..<11)
            #expect(step.h.checkpoints.saved.map(\.doneMs) == [30_000], "a cancel keeps only the earlier checkpoint")
            #expect(decoding.isCancelled)
            decoding.cancel()
            guard case .stopped(.cancel) = step.decode.finish(await decoding.result) else {
                Issue.record("the step ends cancelled")
                return
            }
        }
    }
}
