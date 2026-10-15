import Foundation

/// Mono float samples at their own rate: what the decode rules read.
public struct PcmAudio: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public init(_ samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }
    public var durationMs: Int64 { Int64(samples.count) * 1000 / Int64(sampleRate) }
}
