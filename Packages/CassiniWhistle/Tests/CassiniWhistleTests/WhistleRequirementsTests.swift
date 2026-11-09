import Foundation
import Testing
@testable import CassiniWhistle

/// The OS floor and the CPU rule that decide whether the bundled Whistle can run, for both values of each.
@Suite struct WhistleRequirementsTests {
    // What each chip reports for the features Whistle's archive executes (Arm feature levels of Apple's cores).
    private let a10 = WhistleCPUFeatures(atomics: false, rcpc: false, dotProduct: false) // Armv8.0
    private let a11 = WhistleCPUFeatures(atomics: true, rcpc: false, dotProduct: false)  // Armv8.2
    private let a12 = WhistleCPUFeatures(atomics: true, rcpc: true, dotProduct: false)   // Armv8.3, no dot product
    private let a13 = WhistleCPUFeatures(atomics: true, rcpc: true, dotProduct: true)    // Armv8.4

    @Test func theCPURuleNeedsAtomicsAndRCpcButNeverDotProduct() {
        #expect(WhistleCapability.supports(cpu: a12), "the measured A12 has no dot product and runs the fallback kernels")
        #expect(WhistleCapability.supports(cpu: a13))
        #expect(!WhistleCapability.supports(cpu: a10), "the A10 has neither and would crash on first use")
        #expect(!WhistleCapability.supports(cpu: a11), "the A11 has the atomics but not ldapr")
        for atomics in [false, true] {
            for rcpc in [false, true] {
                for dotProduct in [false, true] {
                    let cpu = WhistleCPUFeatures(atomics: atomics, rcpc: rcpc, dotProduct: dotProduct)
                    #expect(WhistleCapability.supports(cpu: cpu) == (atomics && rcpc))
                }
            }
        }
    }

    @Test func anUnsupportedCPUMakesTheBundledAndTheExperimentalWhistleUnavailable() {
        for supported in [false, true] {
            let bundled = WhistleCapability.bundled(arm64: true, osSupported: true, cpuSupported: supported,
                                                    bundleVerified: true, physicalMemory: 3 << 30)
            #expect(bundled.available == supported)
            let experiment = WhistleCapability.experiment(internalBuild: true, optedIn: true, arm64: true, osSupported: true,
                cpuSupported: supported, physicalMemory: 3 << 30, availableMemory: WhistleCapability.loadHeadroom,
                bundleVerified: true)
            #expect(experiment.available == supported)
        }
        #expect(WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                  pipelineAccepted: true, deviceAccepted: true).cpuSupported,
                "a capability built without a CPU fact keeps today's meaning")
    }

    @Test func theOperatingSystemFloorIsIOS26() {
        #expect(WhistleCapability.minimumOperatingSystemMajor == 26)
        #expect(!WhistleCapability.supports(operatingSystemMajor: 18))
        #expect(!WhistleCapability.supports(operatingSystemMajor: 25))
        #expect(WhistleCapability.supports(operatingSystemMajor: 26))
        #expect(WhistleCapability.supports(operatingSystemMajor: 27))
    }

    /// The floor is the deployment target the framework is linked and pinned for; the two move together.
    @Test func theFloorMatchesThePinnedDeploymentTarget() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pins = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appending(path: "Whistle/pins.json")))
        let target = try #require((pins as? [String: Any])?["deploymentTarget"] as? String)
        #expect(target == "\(WhistleCapability.minimumOperatingSystemMajor).0")
    }
}
