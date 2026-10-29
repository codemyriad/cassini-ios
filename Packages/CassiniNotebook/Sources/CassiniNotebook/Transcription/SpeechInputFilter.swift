import Foundation

/// The high-pass the speech detector's input goes through (D26.1): WebRTC APM's capture filter, a 2nd-order
/// Butterworth at 100 Hz for 16 kHz, as freedesktop webrtc-audio-processing `high_pass_filter.cc` has it. Silero has
/// no DC handling of its own and relies on the capture chain having removed it; a microphone with an ADC offset hides
/// quiet speech from it. Only what the detector hears is filtered: the recognizer, the speakers' input and the
/// recording stay raw.
///
/// The coefficients are exact binary64 literals, with b0 + b1 + b2 == 0 for a true double zero at DC. The arithmetic is
/// scalar Double in Direct Form I, left to right, so every platform computes the same samples.
public struct SpeechInputFilter: Hashable, Sendable {
    /// The stage's name in the shared goldens (`vadInputStage`).
    public static let stage = "silero-input-hpf-butter2-100hz-v1"

    static let b0 = 0.9726138984998437
    static let b1 = -1.9452277969996874
    static let b2 = 0.9726138984998437
    static let a1 = -1.9444776577670935
    static let a2 = 0.9459779362322813

    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    /// Zero state; never primed (zero-state steps of up to ±16000 LSB never made a segment).
    public init() {}

    public mutating func reset() { self = Self() }

    /// One 16 kHz sample through the filter. The output is rounded to Float only here, where it leaves for the detector.
    public mutating func callAsFunction(_ sample: Float) -> Float {
        let x = Double(sample)
        // Each product and sum on its own line, so the compiler cannot fuse them.
        let p0 = Self.b0 * x
        let p1 = Self.b1 * x1
        let p2 = Self.b2 * x2
        let q1 = Self.a1 * y1
        let q2 = Self.a2 * y2
        var y = p0 + p1
        y = y + p2
        y = y - q1
        y = y - q2
        // The denormal guard of libopus dc_reject.
        if y > -1e-25 && y < 1e-25 { y = 0 }
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return Float(y)
    }

    public mutating func callAsFunction(_ samples: some Collection<Float>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        for sample in samples { out.append(self(sample)) }
        return out
    }
}

/// The detector's copy of one track: its 16 kHz samples through one `SpeechInputFilter`, in recording order, so the
/// filter's state runs on across the 28 s windows and their 2 s overlap is filtered once. Holds the samples from the
/// oldest a window can still ask for.
public final class SpeechInput {
    private var filter = SpeechInputFilter()
    private var samples: [Float] = []
    /// The recording position of `samples[0]`.
    private var start: Int64

    /// A track whose filtered samples begin at `start`, with the filter at zero state there.
    public init(start: Int64 = 0) { self.start = start }

    /// The position after the last sample taken.
    public var end: Int64 { start + Int64(samples.count) }

    /// Filters and keeps the next samples of the track.
    public func append(_ next: some Collection<Float>) {
        samples.append(contentsOf: filter(next))
    }

    /// The filtered samples of `[from, from + count)`, nil when they are not all held.
    public func window(from: Int64, count: Int) -> [Float]? {
        guard from >= start, from + Int64(count) <= end else { return nil }
        let offset = Int(from - start)
        return Array(samples[offset..<(offset + count)])
    }

    /// Lets go of the samples before `position`.
    public func discard(before position: Int64) {
        let drop = Int(min(max(0, position - start), Int64(samples.count)))
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        start += Int64(drop)
    }
}
