import Foundation

public struct AudioSummary: Hashable, Sendable {
    public var duration: TimeInterval
    /// Levels sampled across the whole file, 0...1.
    public var waveform: [Float]
    public init(duration: TimeInterval, waveform: [Float]) { self.duration = duration; self.waveform = waveform }
}

/// File-level audio work: reading a summary, compressing a capture, decoding Opus for playback.
public protocol AudioProcessing: Sendable {
    func inspect(_ url: URL) async throws -> AudioSummary
    func compress(_ source: URL, to destination: URL) async throws
    func decodeOpus(_ source: URL, to destination: URL) async throws
}
