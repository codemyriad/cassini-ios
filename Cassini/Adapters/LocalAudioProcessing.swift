import Foundation
import CassiniAudio
import CassiniEngine
import CassiniCore

/// File-level audio work on this device, off the main actor.
struct LocalAudioProcessing: AudioProcessing {
    var onNativeChunk: (@Sendable () throws -> Void)? = nil
    func inspect(_ url: URL) async throws -> AudioSummary {
        let inspection = try await AudioInspection.inspect(url)
        return AudioSummary(duration: inspection.duration, waveform: inspection.waveform)
    }

    func compress(_ source: URL, to destination: URL) async throws {
        try await AudioArchive.compress(source: source, destination: destination)
    }

    func decodeOpus(_ source: URL, to destination: URL) async throws {
        try await CancellableFileWork.run { try OpusAudio.decode(source, to: destination, onChunk: onNativeChunk) }
    }

    func encodeOpus(_ source: URL, to destination: URL) async throws {
        try await CancellableFileWork.run { try OpusAudio.encode(source, to: destination, onChunk: onNativeChunk) }
    }
}
