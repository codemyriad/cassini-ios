import XCTest
import CassiniEngine
import CassiniNotebook
@testable import Cassini

/// The UI-test seeds' saved jobs follow the device's recognizer, so a seeded paused job resumes on that device.
final class TestFixturesTests: XCTestCase {
    private func pausedJob(recognizer: SpeechRecognizer) async throws -> (Job?, CheckpointState?) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try NoteStore(root: root)
        let now = Date(timeIntervalSince1970: 1_791_452_460)
        try await TestFixtures.seed(.statuses, into: store, now: now, recognizer: recognizer)
        let job = try JobRepository(root: root).load().first { $0.noteID == TestFixtures.pausedID }
        return (job, try CheckpointFiles(notes: store).load(TestFixtures.pausedID))
    }

    /// Apple speech's paused job stays a legacy one, with Apple's checkpoint, as before the recognizer was passed.
    func testTheAppleSpeechDevicesPausedJobIsALegacyAppleJob() async throws {
        let (job, checkpoint) = try await pausedJob(recognizer: .appleSpeech)
        XCTAssertEqual(job?.state, .paused)
        XCTAssertNil(job?.recognizer)
        XCTAssertEqual(checkpoint?.model, CheckpointState.appleModel(language: "en-US"))
    }

    /// Without Apple speech (iOS 18) the paused job and its saved progress are the bundled Whistle's.
    func testTheWhistleDevicesPausedJobIsWhistles() async throws {
        let (job, checkpoint) = try await pausedJob(recognizer: .whistle)
        XCTAssertEqual(job?.state, .paused)
        XCTAssertEqual(job?.recognizer, SpeechRecognizer.whistle.rawValue)
        XCTAssertEqual(checkpoint?.model, SpeechRecognizer.whistle.checkpointModel(language: "en-US"))
    }
}
