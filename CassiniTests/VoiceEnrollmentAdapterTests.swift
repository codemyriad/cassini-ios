import XCTest
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class VoiceEnrollmentAdapterTests: XCTestCase {
    func testAutoStopAnalyzesAt45SecondsWithoutCancellingItself() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let capture = EnrollmentCapture()
        let analyzer = successfulAnalyzer()
        let enrollment = makeEnrollment(test, captures: [capture], analyzer: analyzer)
        try await enrollment.start()
        capture.elapsed = 45
        capture.send(.level(0.5))
        await waitUntil { !enrollment.recording && !enrollment.busy }
        XCTAssertNotNil(enrollment.print)
        XCTAssertNil(enrollment.failure)
        XCTAssertFalse(enrollment.tooShort)
        XCTAssertEqual(analyzer.analyzeCount, 1)
        XCTAssertEqual(analyzer.cancelledWhileWaiting, 0)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertTrue(capture.sampleExists)
        await enrollment.cancel()
    }

    func testSecondAttemptReceivesEveryTerminalEventAfterFinishOrCancel() async throws {
        for finishFirst in [true, false] {
            for event in [CaptureEvent.interrupted, .routeLost, .failed, .mediaReset] {
                let test = TestGraph(); defer { test.tearDown() }
                let first = EnrollmentCapture(), second = EnrollmentCapture()
                let enrollment = makeEnrollment(test, captures: [first, second])
                try await enrollment.start()
                if finishFirst { try await enrollment.finish() } else { await enrollment.cancel() }
                try await enrollment.start()
                XCTAssertFalse(first.sampleExists)
                XCTAssertTrue(second.sampleExists)
                second.send(event)
                await waitUntil { !enrollment.recording && !second.sampleExists }
                XCTAssertEqual(second.stops, 1, "\(event), finish first: \(finishFirst)")
                XCTAssertNil(enrollment.print)
                await enrollment.cancel()
            }
        }
    }

    func testSecondAttemptStillAutoStopsAfterFinishOrCancel() async throws {
        for finishFirst in [true, false] {
            let test = TestGraph(); defer { test.tearDown() }
            let first = EnrollmentCapture(), second = EnrollmentCapture()
            let enrollment = makeEnrollment(test, captures: [first, second])
            try await enrollment.start()
            if finishFirst { try await enrollment.finish() } else { await enrollment.cancel() }
            try await enrollment.start()
            second.elapsed = 46
            second.send(.level(0.5))
            await waitUntil { !enrollment.recording && !enrollment.busy }
            XCTAssertNotNil(enrollment.print)
            XCTAssertNil(enrollment.failure)
            XCTAssertEqual(second.stops, 1)
            await enrollment.cancel()
        }
    }

    func testManualFinishReportsTooShortAndAmbiguous() async throws {
        for ambiguous in [false, true] {
            let test = TestGraph(); defer { test.tearDown() }
            let capture = EnrollmentCapture()
            capture.elapsed = ambiguous ? 8 : 3
            let enrollment = makeEnrollment(test, captures: [capture], analyzer: FakeAnalyzer())
            try await enrollment.start()
            try await enrollment.finish()
            XCTAssertTrue(enrollment.tooShort)
            XCTAssertNil(enrollment.print)
            XCTAssertFalse(enrollment.recording)
            XCTAssertFalse(enrollment.busy)
            await enrollment.cancel()
            XCTAssertFalse(capture.sampleExists)
        }
    }

    func testCancelStopsCaptureAndRemovesPartialSample() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let capture = EnrollmentCapture()
        let enrollment = makeEnrollment(test, captures: [capture])
        try await enrollment.start()
        XCTAssertTrue(capture.sampleExists)
        await enrollment.cancel()
        XCTAssertEqual(capture.stops, 1)
        XCTAssertFalse(capture.sampleExists)
        XCTAssertFalse(enrollment.recording)
        XCTAssertNil(enrollment.print)
    }

    func testAutoStopSurfacesStopAnalysisAndCancellationErrorsAndDeletesSample() async throws {
        for failure in 0..<3 {
            let test = TestGraph(); defer { test.tearDown() }
            let capture = EnrollmentCapture()
            if failure == 0 { capture.stopError = CocoaError(.fileWriteUnknown) }
            let analyzer: any SpeakerAnalyzing = failure == 0 ? successfulAnalyzer()
                : FailingEnrollmentAnalyzer(cancelled: failure == 2)
            let enrollment = makeEnrollment(test, captures: [capture], analyzer: analyzer)
            try await enrollment.start()
            capture.elapsed = 45
            capture.send(.level(0.5))
            await waitUntil { enrollment.failure != nil }
            XCTAssertFalse(enrollment.busy)
            XCTAssertFalse(enrollment.recording)
            XCTAssertNil(enrollment.print)
            XCTAssertFalse(capture.sampleExists)
        }
    }

    func testCancelDuringAnalysisCannotRestoreDiscardedPrint() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let capture = EnrollmentCapture(), analyzer = successfulAnalyzer(suspends: true)
        let enrollment = makeEnrollment(test, captures: [capture], analyzer: analyzer)
        try await enrollment.start()
        let finish = Task { try await enrollment.finish() }
        await waitUntil { analyzer.analyzeCount == 1 }
        await enrollment.cancel()
        analyzer.resume()
        try await finish.value
        XCTAssertNil(enrollment.print)
        XCTAssertFalse(capture.sampleExists)
    }

    func testFailedStartRemovesPartialSampleAndNextAttemptUsesNewCapture() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let first = EnrollmentCapture(), second = EnrollmentCapture()
        first.startError = CocoaError(.fileWriteUnknown)
        let enrollment = makeEnrollment(test, captures: [first, second])
        do { try await enrollment.start(); XCTFail("expected start failure") } catch {}
        XCTAssertFalse(first.sampleExists)
        XCTAssertFalse(enrollment.busy)
        try await enrollment.start()
        XCTAssertTrue(second.sampleExists)
        await enrollment.cancel()
    }

    private func successfulAnalyzer(suspends: Bool = false) -> FakeAnalyzer {
        let print = SpeakerPrint(speakerID: "guided", model: VoiceprintModel.sha256,
                                 vector: [1] + Array(repeating: 0, count: VoiceprintModel.dimension - 1), speechSeconds: 8)
        return FakeAnalyzer(analysis: SpeakerAnalysis(turns: [], prints: [print]), suspends: suspends)
    }

    private func makeEnrollment(_ test: TestGraph, captures: [EnrollmentCapture],
                                analyzer: (any SpeakerAnalyzing)? = nil) -> VoiceEnrollmentAdapter {
        var remaining = captures
        return VoiceEnrollmentAdapter(makeCapture: { remaining.removeFirst() }, analyzer: analyzer ?? successfulAnalyzer(),
                                      settings: test.graph.settings, playback: test.graph.playback,
                                      recording: test.graph.recording, root: test.root.appendingPathComponent("Enrollment"))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "timed out")
    }
}

/// Each instance deliberately has one stream, just like AVCaptureAdapter.
@MainActor private final class EnrollmentCapture: AudioCapture {
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    var elapsed: TimeInterval = 8
    var fileBytes: Int64 { 1 }
    var startError: (any Error)?
    var stopError: (any Error)?
    private(set) var url: URL?
    private(set) var stops = 0
    var sampleExists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    init() { (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self) }
    func start(url: URL) async throws -> CaptureFormat {
        self.url = url
        try Data([1]).write(to: url)
        if let startError { throw startError }
        return .pcm48kMono
    }
    func stop() async throws -> CaptureResult {
        stops += 1
        if let stopError { throw stopError }
        return CaptureResult(duration: elapsed)
    }
    func pause() {}
    func resume() throws {}
    func send(_ event: CaptureEvent) { continuation.yield(event) }
}

private struct FailingEnrollmentAnalyzer: SpeakerAnalyzing {
    let cancelled: Bool
    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        if cancelled { throw CancellationError() }
        throw CocoaError(.fileReadCorruptFile)
    }
    func modelStatus() async -> ModelPartStatus { .ready }
    func refreshModelStatus() async -> ModelPartStatus { .ready }
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
    var modelInstallBytes: Int64 { 0 }
}
