import Foundation
import CassiniAudio
import CassiniEngine

/// File-level audio work on this device, off the main actor.
struct LocalAudioProcessing: AudioProcessing {
    func inspect(_ url: URL) async throws -> AudioSummary {
        let inspection = try await AudioInspection.inspect(url)
        return AudioSummary(duration: inspection.duration, waveform: inspection.waveform)
    }

    func compress(_ source: URL, to destination: URL) async throws {
        try await AudioArchive.compress(source: source, destination: destination)
    }

    func decodeOpus(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try OpusAudio.decode(source, to: destination) }.value
    }

    func encodeOpus(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try OpusAudio.encode(source, to: destination) }.value
    }
}
