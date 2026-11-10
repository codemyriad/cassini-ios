import Testing
import CassiniEngine

@Suite struct PlatformFactsTests {
    @Test func iOS26HasBothFactsAndIOS18Neither() {
        #expect(PlatformFacts.iOS26 == PlatformFacts(appleSpeech: true, continuedProcessing: true))
        #expect(PlatformFacts.iOS18 == PlatformFacts(appleSpeech: false, continuedProcessing: false))
    }

    /// Work with progress asks for continued processing only where the system has it; work without progress never
    /// does, on either system.
    @Test func onlyProgressWorkOnASystemWithContinuedProcessingAsksForIt() {
        for continued in [true, false] {
            for appleSpeech in [true, false] {
                let facts = PlatformFacts(appleSpeech: appleSpeech, continuedProcessing: continued)
                #expect(facts.asksForContinuedProcessing(progressUnits: 100) == continued)
                #expect(facts.asksForContinuedProcessing(progressUnits: 1) == continued)
                #expect(!facts.asksForContinuedProcessing(progressUnits: 0))
                #expect(!facts.asksForContinuedProcessing(progressUnits: -1), "an indeterminate Progress has -1 units")
            }
        }
    }

    /// The speech language is named only for Apple speech on a system that has it: on iOS 18 the `.appleSpeech`
    /// identity is the unavailable sentinel, and Settings hides the picker the download screen would point at.
    @Test func onlyAppleSpeechOnASystemWithItAsksForTheSpeechLanguage() {
        #expect(PlatformFacts.iOS26.asksForSpeechLanguage(.appleSpeech))
        #expect(!PlatformFacts.iOS18.asksForSpeechLanguage(.appleSpeech))
        for facts in [PlatformFacts.iOS26, .iOS18] {
            #expect(!facts.asksForSpeechLanguage(.parakeet))
            #expect(!facts.asksForSpeechLanguage(.whistle))
        }
    }
}
