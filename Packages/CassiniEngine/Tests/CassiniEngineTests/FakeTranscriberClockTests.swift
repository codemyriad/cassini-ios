import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@Suite struct FakeTranscriberClockTests {
    private enum Bound: Error { case timeout, ended }

    /// The event is the pass condition; this sleep only bounds a broken test's wait.
    private func next<T: Sendable>(_ stream: AsyncStream<T>) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let event = await iterator.next() else { throw Bound.ended }
                return event
            }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw Bound.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    @Test func aPermitClockCancelsAnActuallyWaitingSleep() async throws {
        let (waiting, entered) = AsyncStream<Void>.makeStream()
        let (finished, ended) = AsyncStream<Bool>.makeStream()
        let clock = PermitClock(now: Date(timeIntervalSince1970: 0), onWaiting: { entered.yield(()) })
        let task = Task {
            do { try await clock.sleep(for: .seconds(1)); ended.yield(false) }
            catch is CancellationError { ended.yield(true) }
            catch { ended.yield(false) }
        }
        defer { task.cancel() }
        _ = try await next(waiting)
        task.cancel()
        #expect(try await next(finished))
        #expect(clock.now == Date(timeIntervalSince1970: 0), "cancellation consumes no virtual time")
    }

    @Test func growthConsumesExactlyTheGrantedResults() async throws {
        let (reports, sink) = AsyncStream<TimeInterval>.makeStream()
        let (waiting, entered) = AsyncStream<Void>.makeStream()
        let clock = PermitClock(now: Date(timeIntervalSince1970: 0), onWaiting: { entered.yield(()) })
        let segments = (0..<5).map { TranscriptSegment(text: "Sentence \($0).", start: Double($0), end: Double($0 + 1)) }
        let fake = FakeTranscriber(.growing(segments, every: .milliseconds(500), total: 5), clock: clock)
        let task = Task {
            try await fake.transcribe(.init(url: URL(fileURLWithPath: "/synthetic.caf"), language: "en", allowDownload: false)) {
                if case .progress(let done, _) = $0 { sink.yield(done) }
            }
        }
        defer { task.cancel() }
        _ = try await next(waiting)
        clock.grant(2)
        #expect(try await next(reports) == 1)
        #expect(try await next(reports) == 2)
        _ = try await next(waiting)
        #expect(clock.now == Date(timeIntervalSince1970: 1))
        clock.grant(1)
        #expect(try await next(reports) == 3)
        #expect(clock.now == Date(timeIntervalSince1970: 1.5))
    }

    @Test func pacedReportsAdvanceVirtualTimeWithoutRealPauses() async throws {
        let (reports, sink) = AsyncStream<(TimeInterval, Int64)>.makeStream()
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        let fake = FakeTranscriber(.frozen(done: 60, total: 100, pace: 10), clock: clock)
        let task = Task {
            try await fake.transcribe(.init(url: URL(fileURLWithPath: "/synthetic.caf"), language: "en", allowDownload: false)) {
                if case .progress(let done, _) = $0 { sink.yield((done, Int64((clock.now.timeIntervalSince1970 * 1_000).rounded()))) }
            }
        }
        defer { task.cancel() }
        let first = try await next(reports), second = try await next(reports), last = try await next(reports)
        #expect(first.0 == 40 && first.1 == 1_200)
        #expect(second.0 == 50 && second.1 == 2_400)
        #expect(last.0 == 60 && last.1 == 3_600)
    }
}
