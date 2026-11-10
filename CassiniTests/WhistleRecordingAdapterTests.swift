import XCTest
import AVFoundation
import Synchronization
import CassiniEngine
import CassiniInference
import CassiniNotebook
import CassiniWhistle

final class WhistleRecordingAdapterTests: XCTestCase {
    func testAdmissionHeadroomCanRecoverWithoutRelaunchAndLoadChecksItAgain() async throws {
        let free = Mutex<Int64>(1)
        let transcriber = WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true,
            bundleVerified: true, pipelineAccepted: true, deviceAccepted: true), availableMemory: { free.withLock { $0 } })
        let first = await transcriber.unavailability(locale: .current)
        XCTAssertEqual(first, .memory)
        free.withLock { $0 = Int64(WhistleCapability.loadHeadroom) }
        let recovered = await transcriber.unavailability(locale: .current)
        XCTAssertNil(recovered)
        free.withLock { $0 = 1 }
        do {
            _ = try await transcriber.transcribe(.init(url: URL(fileURLWithPath: "/must-not-open.wav"), language: "", allowDownload: false)) { _ in }
            XCTFail("Low live headroom must refuse before opening the audio or loading a model")
        } catch { XCTAssertEqual(error as? TranscriptionError, .failed(.memory)) }
    }

    private func transcriber() -> WhistleTranscriber {
        WhistleTranscriber(acceptance: .init(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                            pipelineAccepted: false, deviceAccepted: false, internalExperiment: true),
                           availableMemory: { Int64.max }) // Simulator laboratory admission only.
    }
    func testBundledEnglishRecordingRunsThroughFIRVADAndNeedle() async throws {
        let url = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let languages = Mutex<[String]>([])
        let result = try await transcriber().transcribe(.init(url: url, language: "it-IT", allowDownload: false)) {
            if case .whistleBatch(let batch) = $0 { languages.withLock { $0 += batch.languages } }
        }
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertTrue(result.segments.flatMap(\.words).contains { $0.text.lowercased().contains("country") })
        XCTAssertEqual(Set(languages.withLock { $0 }), ["en"], "detected English, never the Italian UI preference")
        XCTAssertFalse(WhistleCapability.pending(bundleVerified: true).available)
    }
    /// Event-driven pauses before any speech has finalized, after a completed segment, and near EOF.
    /// The saved snapshot is serialized as it is by the real job. A new session restores the FIR and VAD
    /// and uses the actual embedded Needle decoder for the remaining segments.
    func testRepeatedResumeHasExactWordsAndTimingsAndSkipsFinalizedWindows() async throws {
        let source = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try repeatedSpeech(source: source, destination: url)

        let expected = Mutex<[WhistleBatch]>([])
        let reference = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false)) {
            if case .whistleBatch(let batch) = $0 { expected.withLock { $0.append(batch) } }
        }
        XCTAssertGreaterThan(reference.segments.count, 2)
        let referenceBatches = expected.withLock { $0 }
        let first = try XCTUnwrap(referenceBatches.first)
        XCTAssertTrue(first.segments.isEmpty)
        let afterFirstSegment = try XCTUnwrap(referenceBatches.first { !$0.segments.isEmpty })
        let nearEnd = try XCTUnwrap(referenceBatches.last { $0.checkpoint.sourceFrame < 36 * 48_000 })
        let pauses = [first, afterFirstSegment, nearEnd].map(\.checkpoint.sourceFrame)
        XCTAssertEqual(Set(pauses).count, 3)

        var resume: WhistleCheckpoint?
        var actual: [WhistleBatch] = []
        for pause in pauses {
            let batches = Mutex<[WhistleBatch]>([])
            let request = TranscriptionRequest(url: url, language: "", allowDownload: false, whistleResume: resume)
            do {
                _ = try await transcriber().transcribe(request) {
                    guard case .whistleBatch(let batch) = $0 else { return }
                    batches.withLock { $0.append(batch) }
                    if batch.checkpoint.sourceFrame == pause { withUnsafeCurrentTask { $0?.cancel() } }
                }
                XCTFail("The checkpoint event must interrupt this session")
            } catch is CancellationError {}
            let observed = batches.withLock { $0 }
            let last = try XCTUnwrap(observed.last)
            XCTAssertEqual(last.checkpoint.sourceFrame, pause)
            XCTAssertEqual(observed.first?.checkpoint.sourceFrame, (resume?.sourceFrame ?? 0) + 48_000)
            let encoded = try JSONEncoder().encode(last.checkpoint)
            resume = try JSONDecoder().decode(WhistleCheckpoint.self, from: encoded)
            actual += observed
        }
        let last = Mutex<[WhistleBatch]>([])
        _ = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false, whistleResume: resume)) {
            if case .whistleBatch(let batch) = $0 { last.withLock { $0.append(batch) } }
        }
        actual += last.withLock { $0 }
        XCTAssertEqual(actual.map(\.checkpoint.sourceFrame), referenceBatches.map(\.checkpoint.sourceFrame))
        XCTAssertEqual(actual.map(\.languages), referenceBatches.map(\.languages))
        XCTAssertEqual(actual.map(\.checkpoint.doneSamples), referenceBatches.map(\.checkpoint.doneSamples))

        struct WordTimes: Equatable {
            let text: String
            let start: Double
            let end: Double
            init(_ word: TimedWord) { text = word.text; start = word.start; end = word.end }
        }
        let segments = actual.flatMap(\.segments)
        XCTAssertEqual(segments.map(\.text), reference.segments.map(\.text))
        XCTAssertEqual(segments.map(\.start), reference.segments.map(\.start))
        XCTAssertEqual(segments.map(\.end), reference.segments.map(\.end))
        XCTAssertEqual(segments.flatMap(\.words).map(WordTimes.init), reference.segments.flatMap(\.words).map(WordTimes.init))
        for (before, batch) in zip(actual, actual.dropFirst()) {
            let oldest = Double(before.checkpoint.processedSamples - 240_128) / 16_000
            XCTAssertTrue(batch.segments.allSatisfy { $0.start >= oldest },
                          "Each new block decodes at most one retained window of earlier audio")
        }
    }

    private func repeatedSpeech(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: samples)
        let speech = try XCTUnwrap(samples.floatChannelData).pointee
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        let repeatBlock = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12 * 48_000))
        repeatBlock.frameLength = repeatBlock.frameCapacity
        let channel = try XCTUnwrap(repeatBlock.floatChannelData).pointee
        for index in 0..<Int(repeatBlock.frameLength) {
            channel[index] = index / 3 < Int(samples.frameLength) ? speech[index / 3] : 0
        }
        for _ in 0..<3 { try output.write(from: repeatBlock) }
    }

    func testSharedDCRecordingsKeepTheExactDesktopSixBoundaries() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CASSINI_WHISTLE_DC"] else {
            throw XCTSkip("separate mandatory Whistle DC gate supplies the shared vector folder")
        }
        let expected = [[105984,189440], [347648,367616], [371200,413184], [416256,458240], [504320,544256], [547328,589312]]
        for name in ["dc-quiet-jfk-v1.wav", "dc-quiet-jfk-v1-control.wav"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let result = try await transcriber().transcribe(.init(url: url, language: "", allowDownload: false)) { _ in }
            let actual = result.segments.map { [Int(($0.start * 16000).rounded()), Int(($0.end * 16000).rounded())] }
            XCTAssertEqual(actual, expected, name)
            XCTAssertFalse(result.segments.flatMap(\.words).isEmpty)
            print("WHISTLE_DC \(name) \(actual) \(result.segments.map(\.text))")
        }
    }
}
