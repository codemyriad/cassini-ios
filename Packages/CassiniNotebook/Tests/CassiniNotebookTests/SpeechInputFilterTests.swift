import CryptoKit
import Foundation
import Testing
@testable import CassiniNotebook

/// D26.1's high-pass on the speech detector's input (coordination `ux-draft/dc/README.md`). Android has not landed it
/// yet, so there is no test of its to port; the expected samples come from the spec's reference loop in Python
/// (binary64, left to right, Float only on output).
@Suite struct SpeechInputFilterTests {
    /// 16 000 samples of quiet noise around the failing microphone's offset (-2060 of 32768), as PCM16 values, so the
    /// input is exact on every platform: an LCG (`s = s * 1103515245 + 12345 mod 2^31`, from 1) gives
    /// `(s >> 16) % 2001 - 1000 - 2060`.
    static let input: [Float] = {
        var s: UInt64 = 1
        return (0..<16_000).map { _ in
            s = (s &* 1_103_515_245 &+ 12_345) % (1 << 31)
            return Float(Int((s >> 16) % 2001) - 1000 - 2060) / 32768
        }
    }()

    static func sha256(_ samples: [Float]) -> String {
        let bytes = samples.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init) }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func theCoefficientsAreTheSpecsExactLiteralsWithADoubleZeroAtDC() {
        #expect(SpeechInputFilter.b0 == 0.9726138984998437)
        #expect(SpeechInputFilter.b1 == -1.9452277969996874)
        #expect(SpeechInputFilter.b2 == 0.9726138984998437)
        #expect(SpeechInputFilter.a1 == -1.9444776577670935)
        #expect(SpeechInputFilter.a2 == 0.9459779362322813)
        #expect(SpeechInputFilter.b0 + SpeechInputFilter.b1 + SpeechInputFilter.b2 == 0)
        #expect(SpeechInputFilter.stage == "silero-input-hpf-butter2-100hz-v1")
    }

    @Test func theOutputIsTheReferenceLoopsSampleForSample() {
        var filter = SpeechInputFilter()
        let out = filter(Self.input)
        let want: [(Int, UInt32)] = [(0, 0xbd87_8edd), (1, 0xbd0f_7baa), (2, 0xbda7_bbf0), (511, 0xbce8_bf36),
                                     (512, 0x3cd9_0787), (15_999, 0xbcd9_8ec0)]
        for (index, bits) in want { #expect(out[index].bitPattern == bits, "sample \(index)") }
        #expect(Self.sha256(out) == "a73dca42ad99ab799e9c192d35f48f1cd815cca1357742ad43e32d07e73b3408")
    }

    @Test func theOffsetIsGoneAfterHalfASecond() {
        var filter = SpeechInputFilter()
        let out = filter(Self.input)
        let inputMean = Self.input.reduce(0.0) { $0 + Double($1) } / Double(Self.input.count)
        let outputMean = out[8000...].reduce(0.0) { $0 + Double($1) } / 8000
        #expect(abs(inputMean + 2060.0 / 32768) < 0.001)
        #expect(abs(outputMean) < 0.00001)
    }

    /// The state runs on from one call to the next: in pieces of any size, or a sample at a time, the output is the
    /// one of a single pass.
    @Test func theStateCarriesAcrossCalls() {
        var whole = SpeechInputFilter()
        let once = whole(Self.input)
        var pieces = SpeechInputFilter()
        var split: [Float] = []
        var at = 0
        for size in [1, 511, 512, 64, 3000, 7] where at < Self.input.count {
            split += pieces(Self.input[at..<min(at + size, Self.input.count)])
            at += size
        }
        split += pieces(Self.input[at...])
        #expect(split == once)
    }

    @Test func resetReturnsToZeroState() {
        var used = SpeechInputFilter()
        _ = used(Self.input)
        used.reset()
        var fresh = SpeechInputFilter()
        #expect(used == fresh)
        #expect(used(Self.input) == fresh(Self.input))
    }

    /// The denormal guard of libopus dc_reject: an output this close to zero is exactly zero.
    @Test func aTinyOutputIsExactlyZero() {
        var filter = SpeechInputFilter()
        #expect(filter(Float(1e-26)).bitPattern == 0)
        var silent = SpeechInputFilter()
        #expect(silent([Float](repeating: 0, count: 100)).allSatisfy { $0.bitPattern == 0 })
    }

    @Test func theTrackFiltersOnceAcrossOverlappingWindows() throws {
        let track = SpeechInput()
        var filter = SpeechInputFilter()
        let reference = filter(Self.input)
        track.append(Self.input[0..<6000])
        track.append(Self.input[6000...])
        #expect(track.end == 16_000)
        // Two windows with an overlap: the overlap's samples are the ones the first window had.
        #expect(try #require(track.window(from: 0, count: 10_000)) == Array(reference[0..<10_000]))
        track.discard(before: 8000)
        #expect(track.window(from: 7999, count: 10) == nil)
        #expect(try #require(track.window(from: 8000, count: 8000)) == Array(reference[8000...]))
        #expect(track.window(from: 8000, count: 8001) == nil)
    }

    /// A restored run's track starts at its window with the filter at zero state.
    @Test func aTrackCanStartPartWay() throws {
        let track = SpeechInput(start: 448_000)
        track.append(Self.input)
        var filter = SpeechInputFilter()
        #expect(try #require(track.window(from: 448_000, count: 16_000)) == filter(Self.input))
        #expect(track.window(from: 0, count: 1) == nil)
        track.discard(before: 0)
        #expect(track.end == 464_000)
    }
}
