import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting

struct FakeHeldInstallTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func heldProgressRecordsTheActualSpeechRequestAndEndsOnCancellation(checking: Bool) async throws {
        let expected: InstallProgress = checking ? .checking : .downloading(0.46)
        let recorder = FakeModelInstallRecorder()
        let fake = FakeTranscriber(.returns([], total: 1), status: .notDownloaded,
                                   installRecorder: recorder, heldInstallProgress: expected)
        let (events, continuation) = AsyncStream<InstallProgress>.makeStream()
        defer { continuation.finish() }
        let task = Task { try await fake.installAssets(locale: Locale(identifier: "en-US")) { continuation.yield($0) } }
        defer { task.cancel() }
        var iterator = events.makeAsyncIterator()
        let actual = try #require(await iterator.next())
        #expect(actual == expected)
        #expect(recorder.snapshot.requested == [.speech])
        #expect(recorder.snapshot.completed.isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.snapshot.requested == [.speech])
        #expect(recorder.snapshot.completed.isEmpty)
    }
}
