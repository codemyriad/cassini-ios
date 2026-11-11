import Foundation
import Synchronization
import CassiniCore

/// Blocking archive work owns a worker queue; cancellation is checked between bounded reads/writes, including
/// while an operation is already executing. Neither ZIP parsing nor multi-gigabyte I/O runs on the main actor.
enum ArchiveWork {
    final class Budget: Sendable {
        let limit: UInt64
        private let bytes = Mutex(UInt64(0))
        init(_ limit: UInt64) { self.limit = limit }
        var remaining: UInt64 { bytes.withLock { limit - $0 } }
        func observed(_ count: Int) throws {
            try bytes.withLock { value in
                guard UInt64(count) <= limit - value else { throw ZIPFailure.tooLarge }
                value += UInt64(count)
            }
        }
    }
    final class Cancellation: Sendable {
        private let cancelled = Mutex(false)
        func cancel() { cancelled.withLock { $0 = true } }
        func check() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
    }
    static func run<T: Sendable>(on queue: DispatchQueue = .global(qos: .userInitiated),
                                 _ body: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: T = try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try cancellation.check(); return try body(cancellation) }) }
            }
            try Task.checkCancellation()
            return value
        } onCancel: { cancellation.cancel() }
    }
}

/// The non-Sendable file writer is confined to this queue, including construction and closing.
final class ArchiveOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Cassini.archive.output", qos: .userInitiated)
    private var writer: StoredZIPWriter?
    static func create(_ url: URL, limits: ZIPLimits) async throws -> ArchiveOutput {
        let output = ArchiveOutput()
        try await ArchiveWork.run(on: output.queue) { _ in output.writer = try StoredZIPWriter(url: url, limits: limits) }
        return output
    }
    func add(_ url: URL, name: String) async throws {
        try await ArchiveWork.run(on: queue) { [self] cancel in
            guard let writer else { throw ZIPFailure.entry }
            try writer.add(file: url, name: name, check: cancel.check)
        }
    }
    func finish() async throws {
        try await ArchiveWork.run(on: queue) { [self] cancel in
            guard let writer else { throw ZIPFailure.entry }
            try writer.finish(check: cancel.check)
            self.writer = nil
        }
    }
}
