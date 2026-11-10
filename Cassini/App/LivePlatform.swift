import Foundation
import os
import CassiniEngine
import CassiniWhistle

/// The one place the app asks the running system what it offers. The rules take the answers as values
/// (`PlatformFacts`, `WhistleCapability`), so `swift test` covers both sides of each.
///
/// Apple speech and continued processing are iOS 26 APIs; `facts` says the system has them exactly where
/// `#available(iOS 26.0, *)` does, and the adapters that use them check both (`AppEnvironment.appleSpeechCandidate`,
/// `UIKitBackgroundRunner`), so a fact never promises an API the system lacks.
enum LivePlatform {
    /// The iOS 26 facts on iOS 26 and later, the iOS 18 facts below.
    static let facts: PlatformFacts = {
        if #available(iOS 26.0, *) { return .iOS26 }
        return .iOS18
    }()

    static var operatingSystemMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// Whether this iOS is one the bundled Whistle framework is linked for (iOS 18 and later).
    static var whistleOperatingSystemSupported: Bool {
        WhistleCapability.supports(operatingSystemMajor: operatingSystemMajor)
    }

    /// The CPU features the system reports (`hw.optional.arm.FEAT_*`). In the simulator they are the host Mac's.
    static let cpuFeatures: WhistleCPUFeatures = {
        let features = WhistleCPUFeatures(reading: sysctlBytes)
        Logger(subsystem: "io.codemyriad.cassini", category: "WhistleBundle")
            .notice("CPU features; atomics=\(features.atomics, privacy: .public) rcpc=\(features.rcpc, privacy: .public) dotProduct=\(features.dotProduct, privacy: .public)")
        return features
    }()

    /// Whether the CPU has the atomics and RCpc loads the Whistle archive executes (`WhistleCapability.supports(cpu:)`):
    /// the A12 and later do, the A10 of the iPad (7th generation) on iPadOS 18 does not. A key the system does not
    /// answer counts as absent, so Whistle is refused there. Every device iOS 26 runs on is an A12 or newer, and xnu
    /// has published both keys since iOS 15 (xnu-8019), so iOS 26 devices keep Whistle.
    static var whistleCPUSupported: Bool { WhistleCapability.supports(cpu: cpuFeatures) }

    /// The bytes `sysctlbyname` writes for `name`, or nil when it fails (an unknown key, or a value over 8 bytes).
    static func sysctlBytes(_ name: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var size = bytes.count
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return Array(bytes.prefix(size))
    }
}
