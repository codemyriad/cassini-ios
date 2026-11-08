/// Production rollout is separate from artifact compatibility. Simulator parity proves neither a physical
/// device's memory headroom nor the production VAD/pipeline. The initial bundle ships with acceptance pending.
public struct WhistleCapability: Hashable, Sendable {
    public var arm64: Bool
    public var operatingSystemSupported: Bool
    public var bundleVerified: Bool
    public var pipelineAccepted: Bool
    public var deviceAccepted: Bool

    public init(arm64: Bool, operatingSystemSupported: Bool, bundleVerified: Bool,
                pipelineAccepted: Bool, deviceAccepted: Bool) {
        self.arm64 = arm64; self.operatingSystemSupported = operatingSystemSupported
        self.bundleVerified = bundleVerified; self.pipelineAccepted = pipelineAccepted
        self.deviceAccepted = deviceAccepted
    }

    public var available: Bool {
        arm64 && operatingSystemSupported && bundleVerified && pipelineAccepted && deviceAccepted
    }

    /// No RAM threshold invents a successful device measurement. This remains false until reviewed evidence
    /// identifies an accepted device class and production pipeline; the 3 GB lab gate is explicitly pending.
    public static func pending(bundleVerified: Bool) -> Self {
        #if arch(arm64) && os(iOS)
        let supported = true
        #else
        let supported = false
        #endif
        return .init(arm64: supported, operatingSystemSupported: supported, bundleVerified: bundleVerified,
                     pipelineAccepted: false, deviceAccepted: false)
    }
}

/// Candidate selection without loading native code or promising that missing/downloadable assets are installed.
/// An accepted bundled Whistle is the fallback on devices that cannot use Apple or hold Parakeet; an unaccepted
/// bundle never displaces an eligible backend and never makes an unavailable Apple candidate eligible.
public enum WhistleSelection {
    public enum Backend: Hashable, Sendable { case whistle, parakeet, appleSpeech }

    public static func choose(whistle: WhistleCapability, parakeetLinked: Bool, parakeetCapable: Bool,
                              appleEligible: Bool) -> Backend? {
        if whistle.available && (!parakeetCapable || !appleEligible) { return .whistle }
        if parakeetLinked && parakeetCapable { return .parakeet }
        if appleEligible { return .appleSpeech }
        return whistle.available ? .whistle : nil
    }
}
