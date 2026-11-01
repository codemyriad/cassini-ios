import CassiniCore
import Foundation
import Testing
@testable import CassiniNotebook

/// Android's LongRunMeasurementTest: measurements that take minutes, so they run only when CASSINI_MEASURE is set:
///
///     CASSINI_MEASURE=1 swift test --filter LongRunMeasurementTests
///
/// CASSINI_MEASURE_HOURS shortens the checkpoint run (default 10, Android's length).
/// They print what they measure and assert nothing that a slower machine could fail. iOS has no word log and its
/// checkpoint holds segments rather than Android's typed recognizer and diarizer state, so the checkpoint case
/// measures iOS's own path: the recognizer's typed state and the checkpoint encoding, window after window.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CASSINI_MEASURE"] != nil, "Set CASSINI_MEASURE to run"))
struct LongRunMeasurementTests {
    let run = LongRun()
    static let mb = 1_048_576.0

    // ports: LongRunMeasurementTest#checkpointPathOfATenHourRun
    @Test func checkpointPathOfATenHourRun() throws {
        let hours = ProcessInfo.processInfo.environment["CASSINI_MEASURE_HOURS"].flatMap(Int64.init) ?? 10
        let duration = hours * LongRun.hourMs
        let all = run.words(duration)
        var end = 0
        var written = 0
        var nanos: UInt64 = 0
        var nextHour = LongRun.hourMs
        print("hour  words  file_bytes  written_total_MB  path_total_s")
        for doneMs in run.windowEnds(duration) {
            while end < all.count && all[end].endMs <= doneMs { end += 1 }
            let words = Array(all[0..<end])
            let started = DispatchTime.now().uptimeNanoseconds
            let doneSamples = doneMs * Int64(Limits.asrRate) / 1000
            let state = IncrementalState(start: doneSamples - Int64(LongRun.overlapSamples), end: doneSamples,
                                         window: (0..<LongRun.overlapSamples).map { Float($0) / 1e5 }, words: words)
            let checkpoint = CheckpointState(source: "capture.m4a", signature: "\(duration * 6):1", model: "18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9",
                                             segments: run.segments(state.words), doneMs: doneMs, totalMs: duration,
                                             elapsedMs: doneMs / 8, recognition: RecognitionCheckpoint(state))
            let bytes = try checkpoint.encoded().count
            nanos += DispatchTime.now().uptimeNanoseconds - started
            written += bytes
            if doneMs >= nextHour {
                print(String(format: "%4lld %6d %11d %17.1f %15.1f", nextHour / LongRun.hourMs, end, bytes,
                             Double(written) / Self.mb, Double(nanos) / 1e9))
                nextHour += LongRun.hourMs
            }
        }
        print(String(format: "written=%.1f MB path=%.1f s", Double(written) / Self.mb, Double(nanos) / 1e9))
    }

    /// The word body that the seal writes for a long transcript, against the limits of the format code.
    // ports: LongRunMeasurementTest#wordBodyOfLongTranscripts
    @Test func wordBodyOfLongTranscripts() throws {
        print("word body (as Transcript.json writes it)")
        print("hours  words  raw_MB  bytes_per_word  gzip_MB  chunks  encode_s")
        for hours: Int64 in [1, 2, 4, 8, 10, 11, 12] {
            let words = run.words(hours * LongRun.hourMs)
            let started = DispatchTime.now().uptimeNanoseconds
            let body = Transcript(words).json()
            let raw = body.utf8.count
            let encoded = raw <= CassiniPayload.maxRaw
                ? try CassiniPayload.encode(prefix: "CASSINI_TX_X_PAYLOAD_", mime: CassiniPayload.wordMime, text: body) : nil
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            func number(_ key: String) -> Int? {
                if case .number(let text)? = encoded?.ref[key] { return Int(text) }
                return nil
            }
            let gzip = number("gzipBytes").map { String(format: "%7.2f", Double($0) / Self.mb) } ?? "  limit"
            print(String(format: "%5lld %6d %7.2f %15.1f %@ %7d %9.2f", hours, words.count, Double(raw) / Self.mb,
                         Double(raw) / Double(words.count), gzip, number("chunkCount") ?? -1, seconds))
        }
        print("MAX_RAW=\(CassiniPayload.maxRaw / 1_048_576) MB")
    }
}

/// Android's LongRun: a synthetic long transcription with the shapes of a real job: a speaker id of the job's form,
/// about `wordsPerHour` words an hour, a 28 s window that advances 26 s, and a 2 s overlap kept in the checkpoint.
struct LongRun {
    static let hourMs: Int64 = 3_600_000
    static let wordsPerHour: Int64 = 9_500
    static let windowMs = Int64(IncrementalTranscript.windowSamples) * 1000 / 16_000
    static let stepMs = windowMs - 2_000
    static let overlapSamples = 32_000
    static let speakers = 4
    static let turnWords = 23

    /// Real word lengths: Italian and English words, some with the punctuation Parakeet attaches.
    static let text = ("Allora, partiamo dal punto principale della riunione di oggi. The quarterly numbers look better than " +
        "expected, ma dobbiamo ancora verificare le consegne di giovedì e il budget del progetto. " +
        "Can everyone confirm their availability for next week? Perfetto, grazie mille a tutti.").split(separator: " ").map(String.init)

    let prefix = "diar_0f8e2c3a_6b7d_4e1f_9a2b_3c4d5e6f7a8b_"

    /// The words that end at or before `endMs`, in time order.
    func words(_ endMs: Int64) -> [Word] {
        let gap = Self.hourMs / Self.wordsPerHour
        return (0..<Int(endMs / gap)).map { i in
            let start = Int64(i) * gap
            return Word("\(prefix)\(1 + (i / Self.turnWords) % Self.speakers)", start, start + gap * 4 / 5, Self.text[i % Self.text.count])
        }.filter { $0.endMs <= endMs }
    }

    /// iOS's checkpoint form: one segment each `turnWords` words.
    func segments(_ words: [Word]) -> [TranscriptSegment] {
        Swift.stride(from: 0, to: words.count, by: Self.turnWords).map { from in
            let turn = words[from..<min(from + Self.turnWords, words.count)]
            let timed = turn.map { TimedWord(text: $0.text, start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000) }
            return TranscriptSegment(text: turn.map(\.text).joined(separator: " "), start: timed[0].start, end: timed[timed.count - 1].end,
                                     speakerID: turn.first?.speaker, words: timed)
        }
    }

    /// The ends of the windows of a run over `durationMs`: one each 26 s after the first 28 s.
    func windowEnds(_ durationMs: Int64) -> [Int64] { Array(Swift.stride(from: Self.windowMs, through: durationMs, by: Int(Self.stepMs))) }
}
