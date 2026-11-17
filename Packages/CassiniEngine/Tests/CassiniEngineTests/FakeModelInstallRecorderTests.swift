import Testing
import Foundation
import CassiniEngineTesting
import CassiniEngine

@Suite struct FakeModelInstallRecorderTests {
    @Test(arguments: [false, true]) func aHeldDownloadEndsOnCancellationWithoutCompleting(speaker: Bool) async throws {
        let recorder = FakeModelInstallRecorder(holdDownload: true)
        let (progress, continuation) = AsyncStream<Double>.makeStream()
        defer { continuation.finish() }
        let task = Task {
            let report: @Sendable (InstallProgress) -> Void = {
                if case .downloading(let fraction) = $0 { continuation.yield(fraction ?? 0) }
            }
            if speaker { try await FakeAnalyzer(installRecorder: recorder).installModels(progress: report) }
            else { try await FakeTranscriber(.returns([], total: 1), installRecorder: recorder)
                .installAssets(locale: Locale(identifier: "en-US"), progress: report) }
        }
        var next = progress.makeAsyncIterator()
        #expect(await next.next() == 0.46)
        task.cancel()
        do { try await task.value; Issue.record("A cancelled install must not complete") }
        catch is CancellationError {}
        #expect(recorder.snapshot.completed.isEmpty)
    }

    @Test func onlyInstallerCallsWriteTheJournal() async throws {
        let recorder = FakeModelInstallRecorder()
        let speech = FakeTranscriber(.returns([], total: 1), status: .notDownloaded, installRecorder: recorder)
        let speakers = FakeAnalyzer(modelIdentity: nil, installRecorder: recorder)
        _ = await speech.assetStatus(locale: Locale(identifier: "en-US"))
        _ = await speakers.modelStatus()
        #expect(recorder.snapshot.requested.isEmpty)
        #expect(recorder.snapshot.completed.isEmpty)
        try await speech.installAssets(locale: Locale(identifier: "en-US"), progress: { _ in })
        #expect(recorder.snapshot.requested == [.speech])
        #expect(recorder.snapshot.completed == [.speech])
        try await speakers.installModels(progress: { _ in })
        #expect(recorder.snapshot.requested == [.speech, .speakers])
        #expect(recorder.snapshot.completed == [.speech, .speakers])
    }
}
