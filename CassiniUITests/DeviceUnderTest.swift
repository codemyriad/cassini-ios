import Foundation

/// What the system under test offers, as the app composes it at launch. The app reads the platform facts from the
/// system (`LivePlatform`): Apple speech from iOS 26, none below. A test whose expectation depends on them reads them
/// here, so the same test asserts what the app shows on an iOS 18 simulator and on iOS 26 and 27, rather than being
/// skipped on one of them.
///
/// `CASSINI_IOS18_FACTS=1` in the runner's environment (`TEST_RUNNER_CASSINI_IOS18_FACTS=1` for xcodebuild) gives every
/// launch `--ios18-platform` (`launchAndWait`), and these expectations follow: the iOS 18 side of each such test then
/// runs on the iOS 26 and 27 simulators too.
enum DeviceUnderTest {
    /// Whether this run gives every launch the iOS 18 facts.
    static let iOS18Facts = ProcessInfo.processInfo.environment["CASSINI_IOS18_FACTS"] == "1"

    /// Whether the app has Apple speech: its default recognizer at the UI-test defaults, with a Speech language picker
    /// and a row "Managed by iOS" in Settings.
    static let appleSpeech = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 && !iOS18Facts

    /// The launch arguments of a device whose recognizer runs at the UI-test defaults: none where that is Apple
    /// speech; without it, where the default device has no recognizer and Transcribe is disabled, `--parakeet` (the
    /// fake then stands for Parakeet Ultra, which iOS 18 runs on a device that can hold it).
    static var workingSpeech: [String] { appleSpeech ? [] : ["--parakeet"] }
}
