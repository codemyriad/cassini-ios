/// Compatibility and reviewed pipeline/device evidence are independent. D78 uses the iOS26 parity and
/// physical A12/3GB evidence; transient load/window headroom is checked by the recording adapter.
public struct WhistleCapability: Hashable, Sendable {
    public var arm64: Bool
    public var operatingSystemSupported: Bool
    /// The CPU has the features the pinned Needle archive executes unconditionally (`supports(cpu:)`).
    public var cpuSupported: Bool
    public var bundleVerified: Bool
    public var pipelineAccepted: Bool
    public var deviceAccepted: Bool
    /// Explicit internal-test permission; this does not mark the device or production pipeline accepted.
    public var internalExperiment: Bool

    public init(arm64: Bool, operatingSystemSupported: Bool, cpuSupported: Bool = true, bundleVerified: Bool,
                pipelineAccepted: Bool, deviceAccepted: Bool, internalExperiment: Bool = false) {
        self.arm64 = arm64; self.operatingSystemSupported = operatingSystemSupported; self.cpuSupported = cpuSupported
        self.bundleVerified = bundleVerified; self.pipelineAccepted = pipelineAccepted
        self.deviceAccepted = deviceAccepted
        self.internalExperiment = internalExperiment
    }

    public var available: Bool {
        arm64 && operatingSystemSupported && cpuSupported && bundleVerified && ((pipelineAccepted && deviceAccepted) || internalExperiment)
    }

    /// Conservative experiment admission, not a measured device-class support claim. Recheck window headroom
    /// during inference; a remembered preference cannot enable an App Store build or bypass missing assets.
    public static func experiment(internalBuild: Bool, optedIn: Bool, arm64: Bool, osSupported: Bool,
                                  cpuSupported: Bool, physicalMemory: UInt64, availableMemory: UInt64?,
                                  bundleVerified: Bool) -> Self {
        let admitted = internalBuild && optedIn && physicalMemory >= 2 << 30
            && (availableMemory.map { $0 >= loadHeadroom } ?? false)
        return .init(arm64: arm64, operatingSystemSupported: osSupported, cpuSupported: cpuSupported,
                     bundleVerified: bundleVerified,
                     pipelineAccepted: false, deviceAccepted: false, internalExperiment: admitted)
    }
    /// D78 rollout after iOS26 DC/adapter parity and the default-limit A12/3GB physical memory gate.
    /// The minimum reported physical memory admits the measured 3GB class; runtime preflights recheck headroom.
    public static func bundled(arm64: Bool, osSupported: Bool, cpuSupported: Bool, bundleVerified: Bool,
                               physicalMemory: UInt64) -> Self {
        .init(arm64: arm64, operatingSystemSupported: osSupported, cpuSupported: cpuSupported, bundleVerified: bundleVerified,
              pipelineAccepted: true, deviceAccepted: physicalMemory >= 2 << 30)
    }

    /// The oldest iOS major version the bundled framework is linked for and checked on (`scripts/bundle-whistle.py`
    /// links it at 26.0, and `WhistleRuntime` accepts only that manifest). The live app and the internal lab both ask
    /// `supports(operatingSystemMajor:)`.
    public static let minimumOperatingSystemMajor = 26

    public static func supports(operatingSystemMajor major: Int) -> Bool { major >= minimumOperatingSystemMajor }

    /// The pinned device archive executes Armv8.1 atomics (`ldadd`, FEAT_LSE) and Armv8.3 load-acquire RCpc (`ldapr`,
    /// FEAT_LRCPC) unconditionally, in its thread pool and `needle_init`, so a CPU without either crashes on first use
    /// (A10: neither; A11: atomics only). Dot product is not required: the library picks its dot-product kernels at
    /// run time, and the A12, which has none, runs the fallback kernels (measured on the A12/3 GB iPad).
    public static func supports(cpu: WhistleCPUFeatures) -> Bool { cpu.atomics && cpu.rcpc }

    public static let loadHeadroom: UInt64 = 512 << 20
    public static let windowHeadroom: UInt64 = 256 << 20

    /// An explicitly unaccepted bundle stays unavailable. D78 uses the separate bundled factory after the
    /// iOS26 pipeline and physical3GB measurement; a pending input never grants support.
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

/// The CPU features the Whistle rule reads (`WhistleCapability.supports(cpu:)`), as the system reports them. A feature
/// the system does not report (a missing or failing `sysctl` key) counts as absent, so the device is refused.
public struct WhistleCPUFeatures: Hashable, Sendable {
    /// FEAT_LSE, the Armv8.1 large-system-extension atomics (`hw.optional.arm.FEAT_LSE`).
    public var atomics: Bool
    /// FEAT_LRCPC, the Armv8.3 load-acquire RCpc instructions (`hw.optional.arm.FEAT_LRCPC`).
    public var rcpc: Bool
    /// FEAT_DotProd (`hw.optional.arm.FEAT_DotProd`); Whistle runs without it.
    public var dotProduct: Bool

    public init(atomics: Bool, rcpc: Bool, dotProduct: Bool) {
        self.atomics = atomics; self.rcpc = rcpc; self.dotProduct = dotProduct
    }

    /// The `sysctl` keys of the three features (xnu `bsd/kern/kern_mib.c`, under `hw.optional.arm`).
    public static let atomicsKey = "hw.optional.arm.FEAT_LSE"
    public static let rcpcKey = "hw.optional.arm.FEAT_LRCPC"
    public static let dotProductKey = "hw.optional.arm.FEAT_DotProd"

    /// The features as the system reports them, from `read(key)`: the raw bytes `sysctlbyname` wrote for that key, or
    /// nil when the call failed (no such key, or not readable). xnu publishes each key as a 4-byte int, 1 when the CPU
    /// has the feature; a feature counts as present only for a 4-byte nonzero value. A missing key, a failed read or
    /// any other size counts as absent, so an unexpected answer refuses Whistle rather than crash on first use.
    public init(reading read: (String) -> [UInt8]?) {
        func present(_ key: String) -> Bool {
            guard let bytes = read(key), bytes.count == MemoryLayout<Int32>.size else { return false }
            return bytes.contains { $0 != 0 }
        }
        self.init(atomics: present(Self.atomicsKey), rcpc: present(Self.rcpcKey), dotProduct: present(Self.dotProductKey))
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
