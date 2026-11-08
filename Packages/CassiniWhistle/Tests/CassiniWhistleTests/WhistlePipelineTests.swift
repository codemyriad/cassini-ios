import Foundation
import Testing
@testable import CassiniWhistle

@Suite struct WhistlePipelineTests {
    @Test func validFullScalePCMRetainsFIRRingingAndPassesTheNativeInputContract() throws {
        var resampler = try WhistleResampler(rate: 48000)
        let pcm = resampler.feed([Float](repeating: Float(Int16.max) / 32768, count: 512), final: true)
        let peak = try #require(pcm.max())
        #expect(peak > 1.08, "The pinned FIR can overshoot full scale")
        try WhistleRuntime.validatePCM(pcm)
        let invalidInputs: [[Float]] = [[], [.nan], [.infinity], [-.infinity], [Float](repeating: 0, count: 240129)]
        for invalid in invalidInputs {
            #expect(throws: WhistleError.invalidInput) { try WhistleRuntime.validatePCM(invalid) }
        }
        try WhistleRuntime.validatePCM([Float](repeating: 0, count: 240128))
    }

    @Test func resamplingIsChunkInvariantAndRetainsOnlyTheFIRTail() throws {
        let input = (0..<48001).map { Float(sin(Double($0)*0.043))*0.4 }
        var whole = try WhistleResampler(rate: 48000)
        let expected = whole.feed(input, final: true)
        var streaming = try WhistleResampler(rate: 48000)
        var actual: [Float] = []
        for start in stride(from: 0, to: input.count, by: 721) {
            actual += streaming.feed(Array(input[start..<min(start+721,input.count)]))
        }
        actual += streaming.feed([], final: true)
        #expect(actual == expected)
        #expect(actual.count == 16001)
        #expect(throws: WhistleError.self) { _ = try WhistleResampler(rate: 44100) }
        var passthrough = try WhistleResampler(rate: 16000)
        #expect(passthrough.feed(input, final: true) == input)
    }
    @Test func gateUsesDesktopVotesHysteresisAndSilenceBoundary() throws {
        var gate = WhistleSpeechGate(), frame = 0
        let result = gate.feed([Float](repeating: 0, count: 512*21)) { _ in
            defer { frame += 1 }; return frame < 2 ? 0.7 : 0.1
        }
        #expect(result.count == 1)
        #expect(result.first?.startSample == 0)
        #expect(result.first?.endSample == 10752)
        #expect(result.first?.reason == "silence")
        #expect(gate.flush().isEmpty)
    }
    @Test func gateBoundsAnUnbrokenSpeechSegmentAtTheDesktopFrameBoundary() {
        var gate = WhistleSpeechGate()
        let result = gate.feed([Float](repeating: 0.1, count: 512*469)) { _ in 1 }
        #expect(result.count == 1)
        #expect(result.first?.endSample == 240128)
        #expect(result.first?.reason == "durationLimit")
        #expect(gate.retainedStart >= 235008)
    }
    @Test func binaryIdentityPinsPayloadRatherThanMutableSigningTail() throws {
        var image = Data(repeating: 0, count: 320)
        func put(_ value: UInt32, _ at: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { image.replaceSubrange(at..<at+4, with: $0) }
        }
        put(0xfeedfacf,0); put(0x100000c,4); put(6,12); put(1,16); put(152,20)
        put(0x19,32); put(152,36); put(1,96)
        put(16,144); put(192,152); put(0x80000400,168)
        let before = try WhistleBinaryIdentity.digest(image)
        image[319] = 91
        #expect(try WhistleBinaryIdentity.digest(image) == before)
        image[192] = 1
        #expect(try WhistleBinaryIdentity.digest(image) != before)
        put(UInt32.max,152)
        #expect(throws: WhistleError.self) { try WhistleBinaryIdentity.digest(image) }
        #expect(throws: WhistleError.self) { try WhistleBinaryIdentity.digest(Data()) }
    }
}
