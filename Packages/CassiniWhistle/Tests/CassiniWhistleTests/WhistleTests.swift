import Foundation
import Testing
@testable import CassiniWhistle

struct WhistleTests {
    private let accepted = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                              pipelineAccepted: true, deviceAccepted: true)

    @Test func bundledRolloutRetainsTheMeasuredClassFloorAndVerifiedPins() {
        func fact(arm64: Bool = true, os: Bool = true, pins: Bool = true, ram: UInt64 = 3 << 30) -> WhistleCapability {
            .bundled(arm64: arm64, osSupported: os, cpuSupported: true, bundleVerified: pins, physicalMemory: ram)
        }
        #expect(fact().available)
        #expect(!fact(arm64: false).available)
        #expect(!fact(os: false).available)
        #expect(!fact(pins: false).available)
        #expect(!fact(ram: (2 << 30) - 1).available)
        #expect(!fact().internalExperiment)
    }

    @Test func everyEligibilityFactIsRequired() {
        for bit in 0..<5 {
            var facts = accepted
            switch bit {
            case 0: facts.arm64 = false
            case 1: facts.operatingSystemSupported = false
            case 2: facts.bundleVerified = false
            case 3: facts.pipelineAccepted = false
            default: facts.deviceAccepted = false
            }
            #expect(!facts.available)
            #expect(WhistleSelection.choose(whistle: facts, parakeetLinked: false,
                                            parakeetCapable: false, appleEligible: false) == nil)
        }
        #expect(accepted.available)
        #expect(!WhistleCapability.pending(bundleVerified: true).available)
    }

    @Test func capabilitySelectionKeepsImpossibleBackendsUnavailable() {
        for linked in [true, false] {
            for capable in [true, false] {
                for apple in [true, false] {
                    let chosen = WhistleSelection.choose(whistle: accepted, parakeetLinked: linked,
                                                         parakeetCapable: capable, appleEligible: apple)
                    if !capable || !apple { #expect(chosen == .whistle) }
                    else { #expect(chosen == (linked ? .parakeet : .appleSpeech)) }
                    let gated = WhistleSelection.choose(whistle: .pending(bundleVerified: true), parakeetLinked: linked,
                                                        parakeetCapable: capable, appleEligible: apple)
                    #expect(gated == (linked && capable ? .parakeet : apple ? .appleSpeech : nil))
                }
            }
        }
    }

    @Test func eachWrongOrMissingPrivacyFlagRefusesBeforeLoad() throws {
        for key in WhistlePrivacy.required.keys {
            for value in [String?.none, "incorrect"] {
                var environment = WhistlePrivacy.required
                environment[key] = value
                var entered = false
                #expect(throws: WhistleError.privacy) {
                    try WhistlePrivacy.enter(environment: environment) { entered = true }
                }
                #expect(!entered)
            }
        }
        #expect(try WhistlePrivacy.enter(environment: WhistlePrivacy.required) { 42 } == 42)
    }

    @Test func invalidNativeWordsAreNeverPublished() throws {
        func data(_ start: String, _ end: String, probability: String = "0.9") -> Data {
            Data("{\"text\":\"Hello\",\"language\":\"en\",\"words\":[{\"word\":\"Hello\",\"start\":\(start),\"end\":\(end),\"probability\":\(probability)}]}".utf8)
        }
        #expect(try WhistleResult.parse(data("0", "1"), samples: 16_000).words.first?.word == "Hello")
        for bad in [data("-1", "0"), data("0.5", "0.4"), data("0", "2"), data("0", "1", probability: "2")] {
            #expect(throws: WhistleError.invalidOutput) { try WhistleResult.parse(bad, samples: 16_000) }
        }
        #expect(throws: WhistleError.invalidInput) { try WhistleResult.parse(data("0", "1"), samples: 0) }
        // Desktop's 15 s cut is rounded up to its 512-sample VAD frame, yielding 240128 samples.
        #expect(try WhistleResult.parse(data("0", "1"), samples: 240_128).words.count == 1)
        #expect(throws: WhistleError.invalidInput) { try WhistleResult.parse(data("0", "1"), samples: 240_129) }
    }

    @Test func unacceptedDeviceCannotEnterNativeCode() async {
        await #expect(throws: WhistleError.unavailable) {
            try await WhistleRuntime.shared.transcribe([0], acceptance: .pending(bundleVerified: true))
        }
    }
}
