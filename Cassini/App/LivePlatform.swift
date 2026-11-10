import Foundation
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

    /// Whether this iOS is one the bundled Whistle framework is linked for (iOS 26 until Whistle is linked for 18).
    static var whistleOperatingSystemSupported: Bool {
        WhistleCapability.supports(operatingSystemMajor: operatingSystemMajor)
    }

    /// Whistle is offered only from its OS floor, iOS 26, and every device iOS 26 runs on is an A12 or newer, which
    /// has the atomics and RCpc loads Whistle executes (`WhistleCapability.supports(cpu:)`). Linking Whistle for an
    /// older iOS replaces this with the CPU's reported features.
    static let whistleCPUSupported = true
}
