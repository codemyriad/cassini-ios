import Testing
@testable import CassiniWhistle

@Suite struct WhistleExperimentTests {
    private func capability(internalBuild: Bool = true, optedIn: Bool = true, arm64: Bool = true,
                            os: Bool = true, ram: UInt64 = 3 << 30, free: UInt64? = 768 << 20,
                            verified: Bool = true) -> WhistleCapability {
        .experiment(internalBuild: internalBuild, optedIn: optedIn, arm64: arm64, osSupported: os,
                    physicalMemory: ram, availableMemory: free, bundleVerified: verified)
    }
    @Test func threeGBArm64IOS26CanOptIntoAnExperimentWithoutAcceptingItsClass() {
        let c = capability()
        #expect(c.available)
        #expect(!c.deviceAccepted && !c.pipelineAccepted)
        #expect(!capability(internalBuild: false).available)
        #expect(!capability(optedIn: false).available)
        #expect(!capability(arm64: false).available)
        #expect(!capability(os: false).available)
        #expect(!capability(ram: 1 << 30).available)
        #expect(!capability(free: nil).available)
        #expect(!capability(free: WhistleCapability.loadHeadroom-1).available)
        #expect(!capability(verified: false).available)
        #expect(capability(free: WhistleCapability.loadHeadroom).available)
        #expect(!WhistleCapability.pending(bundleVerified: true).available)
    }
}
