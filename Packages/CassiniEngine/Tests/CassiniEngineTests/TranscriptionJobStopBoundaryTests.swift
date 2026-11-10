import CassiniCore
import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionJobTests {
    /// The words step honours a stop at the next result or window, with no stop watch involved: the job tests stop
    /// once a result or window is in and hold the decode until the watch cancels it (D88), so they no longer reach this
    /// boundary, which a stop asked while a native call runs does. Here the results and windows go to the step
    /// directly, in order.
    @Suite struct StopBoundary {
        /// The words step of a fresh run over the scripted 70 s. Keep it in step with `TranscriptionJob.decodeWords`,
        /// which sets up the job's own: a fresh run there has no checkpoint and no resume offset.
        struct Step {
            let h: Harness
            let stop = StopSignal()
            let decode: WordsDecode
            let events = EventLog()
            let script = ScriptedTranscriber.seventySeconds

            /// Apple Speech's clock moves 10 s on each read, so each result is due a checkpoint by time; Parakeet's
            /// stands still, so only the first window is due one and a later save can come only from a stop.
            init(recognizer: SpeechRecognizer = .appleSpeech) async throws {
                let h = try await Harness()
                self.h = h
                let events = events
                let uptimeMs: @Sendable () -> Int64
                if recognizer == .parakeet {
                    let uptime = ManualUptime()
                    uptimeMs = { uptime.value }
                } else {
                    let uptime = FakeUptime()
                    uptimeMs = { uptime.next() }
                }
                decode = WordsDecode(
                    base: CheckpointState(source: "audio.m4a", signature: CheckpointState.signature(of: h.audioURL),
                                          model: recognizer.checkpointModel(language: "it-IT"), segments: [], doneMs: 0,
                                          totalMs: 70_000, elapsedMs: 0),
                    noteID: h.noteID, resumeDoneMs: 0, recognizer: recognizer, language: "it-IT", limits: h.limits,
                    checkpoints: h.checkpoints, stop: stop, events: { event in events.list.withLock { $0.append(event) } },
                    uptimeMs: uptimeMs)
            }

            /// A Parakeet window decoded up to `seconds`, a word in each second, as `WindowedTranscriber` reports one.
            static func window(upTo seconds: Int64) -> TranscriptWindow {
                let words = (0..<seconds).map { n in Word("", n * 1000, n * 1000 + 800, "w\(n)") }
                let samples = seconds * Int64(CassiniNotebook.Limits.asrRate)
                return TranscriptWindow(words: words, recognition: RecognitionCheckpoint(start: 0, end: samples, position: samples),
                                        inferenceMs: seconds * 10)
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
            // No checkpoint is due between 45 and 55 s, so these two are what show the stop was honoured at result 9.
            #expect(decoding.isCancelled, "the transcriber is cancelled once the stop is honoured")
            #expect(step.events.list.withLock { $0.contains(.stopping) })
            decoding.cancel()
            guard case .stopped(.cancel) = step.decode.finish(await decoding.result) else {
                Issue.record("the step ends cancelled")
                return
            }
        }

        /// A stop asked while a Parakeet window decodes is honoured once that window lands, with its words saved.
        @Test func aPauseAskedWhileAWindowDecodesIsHonouredAtThatWindowWithItsCheckpoint() async throws {
            let step = try await Step(recognizer: .parakeet)
            let decoding = Task<TranscriptionResult, any Error> { try await holdUntilTheJobCancels(); throw CancellationError() }
            step.decode.attach(decoding)
            step.decode.handle(.window(Step.window(upTo: 10)))
            #expect(step.h.checkpoints.saved.map(\.doneMs) == [10_000])

            step.stop.stop(.pause(.user))
            let landed = Step.window(upTo: 20)
            step.decode.handle(.window(landed))
            step.decode.handle(.window(Step.window(upTo: 30)))
            // The window the stop arrived during is kept, and the step ends there: the next one is not taken.
            #expect(step.h.checkpoints.saved.map(\.doneMs) == [10_000, 20_000])
            #expect(step.h.checkpoints.saved.last?.wordsComplete == false)
            #expect(step.h.checkpoints.saved.last?.segments.flatMap(\.words).map(\.text) == landed.words.map(\.text))
            #expect(step.h.checkpoints.saved.last?.recognition == landed.recognition)
            #expect(decoding.isCancelled, "the transcriber is cancelled once the stop is honoured")
            decoding.cancel()
            #expect(step.events.list.withLock { $0.contains(.stopping) })
            guard case .stopped(.pause(.user)) = step.decode.finish(await decoding.result) else {
                Issue.record("the step ends paused")
                return
            }
        }
    }
}
