import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionJobTests {
    /// What a job refuses or fails before or during its work: consent, the language, the limits, a checkpoint that no longer matches.
    @Suite struct Refusals {
        // ports: TranscriptionJobTest#withoutConsentNothingIsInstalledAndNothingIsDecoded
        @Test func withoutConsentNothingIsDownloadedAndNothingIsDecoded() async throws {
            let h = try await Harness(speechStatus: .notDownloaded, settings: JobSettings(
                allowSpeechDownload: false, identifySpeakers: true, allowSpeakerDownload: false))
            let (outcome, events) = await h.run()
            #expect(outcome == .needsConsent(missingBytes: 0))
            #expect(h.transcriber.starts.isEmpty)
            #expect(h.checkpoints.saved.isEmpty)
            #expect(!events.contains { if case .downloading = $0 { true } else { false } })
        }

        @Test func anUnsupportedLanguageFailsBeforeAnyWork() async throws {
            let h = try await Harness(speechStatus: .unsupported)
            #expect(await h.run().outcome == .failed(.unsupportedLanguage))
            #expect(h.transcriber.starts.isEmpty)
        }

        // ports: TranscriptionJobTest#aStopDuringTheDownloadStopsWaitingAndPauses
        @Test func aStopDuringTheDownloadStopsWaitingAndPauses() async throws {
            let h = try await Harness(speechStatus: .notDownloaded)
            h.transcriber.downloadsFirst = true
            h.transcriber.hangs = true
            let stop = StopSignal()
            let running = Task { await h.run(stop: stop) }
            try await h.until("the model downloads") { !h.transcriber.starts.isEmpty }
            stop.stop(.pause(.system))
            let (outcome, events) = await running.value
            #expect(outcome == .paused(.system))
            #expect(events.contains { if case .downloading = $0 { true } else { false } })
            #expect(h.checkpoints.saved.isEmpty)
        }

        // ports: TranscriptionJobTest#audioLongerThanTheLimitFailsBeforeAnyWork
        @Test func audioLongerThanTheLimitFailsBeforeAnyWork() async throws {
            let h = try await Harness(speechStatus: .notDownloaded, limits: .init(maxDurationMs: 60_000))
            #expect(await h.run().outcome == .failed(.long))
            #expect(h.transcriber.starts.isEmpty, "nothing is decoded")
            #expect(h.checkpoints.saved.isEmpty)
        }

        // ports: TranscriptionJobTest#aContainerDurationOverTheLimitFailsAtTheFirstBlock
        @Test func aFileDurationOverTheLimitFailsAtTheFirstResult() async throws {
            let h = try await Harness(duration: 0, limits: .init(maxDurationMs: 60_000))
            #expect(await h.run().outcome == .failed(.long))
            #expect(h.transcriber.emitted <= 1, "no more results are taken")
            #expect(h.checkpoints.saved.isEmpty)
        }

        // ports: TranscriptionJobTest#aLongRecordingIsNotRefusedForItsDuration
        @Test func aLongRecordingIsNotRefusedForItsDuration() async throws {
            let h = try await Harness(duration: 30 * 3600)
            #expect(await h.run().outcome == .done)
        }

        @Test func audioUnder200MillisecondsIsTooShort() async throws {
            let before = try await Harness(duration: 0.1)
            #expect(await before.run().outcome == .failed(.short))
            #expect(before.transcriber.starts.isEmpty)

            let after = try await Harness(duration: 0, script: [])
            after.transcriber.total = 0.15
            #expect(await after.run().outcome == .failed(.short))
        }

        // ports: TranscriptionJobTest#wordsThatOutgrowTheWordBodyFailAtTheWindowThatPassesTheLimit
        @Test func wordsThatOutgrowTheWordBodyFailAtTheCheckpointThatPassesTheLimit() async throws {
            let h = try await Harness(limits: .init(maxBodyBytes: 4_000))
            let (outcome, events) = await h.run()
            #expect(outcome == .failed(.long))
            #expect(h.checkpoints.saved.map(\.doneMs) == [30_000], "the checkpoint before the limit stays")
            #expect(!events.contains { if case .namingClosed = $0 { true } else { false } })

            // Transcribe again resumes from that checkpoint and fails again at the same point, not after a full run.
            let (again, _) = await h.run()
            #expect(again == .failed(.long))
            #expect(h.transcriber.starts == [0, 29])
        }

        // ports: TranscriptionJobTest#aCheckpointThatNoLongerMatchesFailsTheJob
        @Test func aCheckpointThatNoLongerMatchesFailsTheJob() async throws {
            let h = try await Harness()
            try h.files.save(CheckpointState(source: "audio.m4a", signature: "1:2", model: CheckpointState.appleModel(language: "it-IT"), segments: [],
                                             doneMs: 0, totalMs: 70_000, elapsedMs: 0), for: h.noteID)
            #expect(await h.run().outcome == .failed(.checkpointMismatch))
            #expect(h.transcriber.starts.isEmpty)

            let damaged = try await Harness()
            let folder = damaged.files.directory(for: damaged.noteID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{".utf8).write(to: folder.appendingPathComponent(CheckpointFiles.filename))
            #expect(await damaged.run().outcome == .failed(.checkpointMismatch))
        }

        @Test func aChangedLanguageNoLongerMatches() async throws {
            let h = try await Harness()
            let stop = StopSignal()
            h.transcriber.beforeSegment = { index in if index == 7 { stop.stop(.pause(.user)) } }
            _ = await h.run(stop: stop)
            #expect(await h.run(language: "en-US").outcome == .failed(.checkpointMismatch))
        }
    }
}
