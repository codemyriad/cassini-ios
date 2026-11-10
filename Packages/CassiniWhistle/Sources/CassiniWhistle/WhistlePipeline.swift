// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CWhistleDSP



/// D11's centred FIR, bounded to a decoder batch plus its 96-sample overlap.
public struct WhistleResampler {
    private let coefficients: [Float]
    private let rate: Int
    private var samples: [Float] = []
    private var base = 0, count = 0, next = 0
    public init(rate: Int) throws {
        guard rate == 16000 || rate == 48000 else { throw WhistleError.invalidInput }
        self.rate = rate
        struct Filter: Decodable { let coefficients: [Float] }
        coefficients = try JSONDecoder().decode(Filter.self, from: Data(contentsOf: Bundle.module.url(forResource: "fir-48k-16k", withExtension: "json")!)).coefficients
        guard coefficients.count == 97 else { throw WhistleError.invalidInput }
    }
    public struct State: Codable, Sendable {
        fileprivate let samples: [Float]
        fileprivate let base: Int
        fileprivate let count: Int
        fileprivate let next: Int
    }
    public var state: State { State(samples: samples, base: base, count: count, next: next) }

    public mutating func restore(_ state: State, inputCount: Int, outputCount: Int) throws {
        if rate == 16000 {
            guard state.samples.isEmpty, state.base == 0, state.count == 0, state.next == 0,
                  inputCount == outputCount else { throw WhistleError.invalidInput }
        } else {
            guard state.count == inputCount, state.next == outputCount,
                  state.base == max(0, outputCount * 3 - 48),
                  state.base <= inputCount, state.samples.count == inputCount - state.base,
                  state.samples.count <= 97, state.samples.allSatisfy(\.isFinite) else {
                throw WhistleError.invalidInput
            }
        }
        samples = state.samples; base = state.base; count = state.count; next = state.next
    }

    public mutating func feed(_ input: [Float], final: Bool = false) -> [Float] {
        if rate == 16000 { return input }
        samples.append(contentsOf: input); count += input.count
        var output: [Float] = []
        let limit = final ? (count + 2) / 3 : max(0, (count - 49) / 3 + 1)
        // Keep the exact scalar binary64 operation order without paying Swift's
        // unoptimized generic collection/indexing cost for every one of 97 taps.
        let first = next, retainedBase = base, total = count
        output = [Float](repeating:0,count:max(0,limit-first))
        if !output.isEmpty {
            coefficients.withUnsafeBufferPointer { taps in
                samples.withUnsafeBufferPointer { input in
                    output.withUnsafeMutableBufferPointer { result in
                        cassini_whistle_fir(taps.baseAddress,input.baseAddress,Int64(retainedBase),Int64(total),Int64(first),result.baseAddress,result.count)
                    }
                }
            }
        }
        next = first+output.count
        let remove = min(samples.count, max(0, next * 3 - 48 - base))
        samples.removeFirst(remove); base += remove
        return output
    }
}

public struct WhistleSegment: Codable, Equatable, Sendable {
    public let startSample: Int
    public let endSample: Int
    public let reason: String
}
/// Exact cassini-live WhistleSpeechGate decisions. Live's one-second handoff chunks are
/// aggregated into contiguous ranges; no samples are replayed or resynthesised.
public struct WhistleSpeechGate: Codable, Sendable {
    private var tail: [Float] = [], votes: [Bool] = []
    private var preCount = 0
    private var active = false, quiet = 0, duration = 0, position = 0, start = 0
    public init() {}
    public func valid(at total: Int) -> Bool {
        position >= 0 && position <= total && position.isMultiple(of: 512)
            && tail.count < 512 && tail.count == total - position && tail.allSatisfy(\.isFinite)
            && (0...10).contains(preCount) && votes.count <= 3 && (0...19).contains(quiet)
            && start >= 0 && start <= position && (0...240_128).contains(duration)
            && (!active || (duration == position - start && preCount == 0 && votes.isEmpty))
    }
    public var retainedStart: Int { active ? start : max(0, position - 5120) }
    public mutating func feed(_ samples: [Float], probability: ([Float]) throws -> Float) rethrows -> [WhistleSegment] {
        tail.append(contentsOf: samples)
        var segments: [WhistleSegment] = [], consumed = 0
        while tail.count - consumed >= 512 {
            let frame = Array(tail[consumed..<consumed + 512]); consumed += 512; position += 512
            let voiced = try probability(frame) >= (active ? 0.35 : 0.5)
            if !active {
                preCount = min(preCount + 1, 10)
                votes.append(voiced); if votes.count > 3 { votes.removeFirst() }
                guard votes.filter({ $0 }).count >= 2 else { continue }
                active = true; duration = preCount * 512; start = position - duration
                preCount = 0; votes.removeAll(keepingCapacity: true)
            } else { duration += 512 }
            quiet = voiced ? 0 : quiet + 1
            let reason: String?
            if quiet * 512 >= 9600 { reason = "silence" }
            else if duration >= 224000 && quiet * 512 >= 2048 { reason = "durationPause" }
            else if duration >= 240000 { reason = "durationLimit" }
            else { reason = nil }
            if let reason {
                segments.append(.init(startSample: start, endSample: position, reason: reason)); active = false; quiet = 0
            }
        }
        tail.removeFirst(consumed)
        return segments
    }
    public mutating func flush() -> [WhistleSegment] {
        let result: [WhistleSegment] = active ? [.init(startSample: start, endSample: position + tail.count, reason: "flush")] : []
        self = Self(); return result
    }
}
