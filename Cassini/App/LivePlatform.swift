import Foundation
import CassiniEngine
import CassiniWhistle

/// The one place the app asks the running system what it offers. The rules take the answers as values
/// (`PlatformFacts`, `WhistleCapability`), so `swift test` covers both sides of each.
///
/// The deployment target is iOS 26.0, so every iOS 26 feature is there and every device is an A12 or newer. A lower
/// target replaces the constants below with `#available` checks and the CPU's reported features.
enum LivePlatform {
    /// Apple speech and continued processing, both iOS 26.
    static let facts = PlatformFacts.iOS26

    static var operatingSystemMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// Whether this iOS is one the bundled Whistle framework is linked for.
    static var whistleOperatingSystemSupported: Bool {
        WhistleCapability.supports(operatingSystemMajor: operatingSystemMajor)
    }

    /// Every device iOS 26 runs on is an A12 or newer, which has the atomics and RCpc loads Whistle executes
    /// (`WhistleCapability.supports(cpu:)`).
    static let whistleCPUSupported = true
}
