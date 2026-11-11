import Foundation
import CassiniAudio
import CassiniEngine

/// File-level audio work on this device, off the main actor.
struct LocalAudioProcessing: AudioProcessing {
    private let encode: @Sendable (URL, URL) throws -> Void
    private let decode: @Sendable (URL, URL) throws -> Void

    init(encode: @escaping @Sendable (URL, URL) throws -> Void = { try OpusAudio.encode($0, to: $1) },
         decode: @escaping @Sendable (URL, URL) throws -> Void = { try OpusAudio.decode($0, to: $1) }) {
        self.encode = encode; self.decode = decode
    }

    /// A detached worker must receive the caller's cancellation: awaiting its value does not link it.
    private static func run(_ operation: @escaping @Sendable () throws -> Void) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try operation()
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            do { try await worker.value; try Task.checkCancellation() }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            worker.cancel()
        }
    }

    func inspect(_ url: URL) async throws -> AudioSummary {
        let inspection = try await AudioInspection.inspect(url)
        return AudioSummary(duration: inspection.duration, waveform: inspection.waveform)
    }

    func compress(_ source: URL, to destination: URL) async throws {
        try await AudioArchive.compress(source: source, destination: destination)
    }

    func decodeOpus(_ source: URL, to destination: URL) async throws {
        try await Self.run { try decode(source, destination) }
    }

    func encodeOpus(_ source: URL, to destination: URL) async throws {
        try await Self.run { try encode(source, destination) }
    }
}
