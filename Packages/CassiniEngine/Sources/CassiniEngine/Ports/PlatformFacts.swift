import Foundation

/// What the running system offers that Cassini's rules depend on. The app reads it once (`LivePlatform`) and passes
/// it in, so the rules never ask the OS themselves and `swift test` covers both values of each fact.
public struct PlatformFacts: Hashable, Sendable {
    /// Apple's on-device speech model (`SpeechAnalyzer`, iOS 26). Without it Apple speech is never selected, and
    /// Settings offers neither its speech language nor "Managed by iOS".
    public var appleSpeech: Bool
    /// Continued background processing (`BGContinuedProcessingTask`, iOS 26). Without it work that leaves the screen
    /// gets only the finite background time.
    public var continuedProcessing: Bool

    public init(appleSpeech: Bool, continuedProcessing: Bool) {
        self.appleSpeech = appleSpeech; self.continuedProcessing = continuedProcessing
    }

    /// iOS 26 and later.
    public static let iOS26 = PlatformFacts(appleSpeech: true, continuedProcessing: true)
    /// iOS 18: neither.
    public static let iOS18 = PlatformFacts(appleSpeech: false, continuedProcessing: false)

    /// Whether Cassini names `recognizer`'s speech language (the Settings picker, its footers and the download
    /// screen's "change it in Settings › Speech language"): only a recognizer that takes a language, on a system with
    /// Apple speech. Without it the `.appleSpeech` identity is only the unavailable sentinel, and the picker is hidden.
    public func asksForSpeechLanguage(_ recognizer: SpeechRecognizer) -> Bool {
        appleSpeech && recognizer.usesLanguage
    }

    /// Whether work that reports `progressUnits` asks iOS for continued processing (its title, progress and Stop
    /// button); otherwise, and for work without progress, the runner takes the finite background time.
    public func asksForContinuedProcessing(progressUnits: Int64) -> Bool {
        continuedProcessing && progressUnits > 0
    }
}
