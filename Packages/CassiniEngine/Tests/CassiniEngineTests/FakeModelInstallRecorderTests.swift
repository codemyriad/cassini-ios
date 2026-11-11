import Testing
import Foundation
import CassiniEngineTesting

@Suite struct FakeModelInstallRecorderTests {
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
