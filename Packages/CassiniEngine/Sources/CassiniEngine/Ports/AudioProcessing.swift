import Foundation

public struct AudioSummary: Hashable, Sendable {
    public var duration: TimeInterval
    /// Levels sampled across the whole file, 0...1.
    public var waveform: [Float]
    public init(duration: TimeInterval, waveform: [Float]) { self.duration = duration; self.waveform = waveform }
}

/// File-level audio work: reading a summary, compressing a capture, decoding Opus for playback and encoding it for a
/// Cassini document.
public protocol AudioProcessing: Sendable {
    func inspect(_ url: URL) async throws -> AudioSummary
    func compress(_ source: URL, to destination: URL) async throws
    func decodeOpus(_ source: URL, to destination: URL) async throws
    /// Encodes any audio file as 48 kHz mono Ogg Opus, mixing every channel down.
    func encodeOpus(_ source: URL, to destination: URL) async throws
}
