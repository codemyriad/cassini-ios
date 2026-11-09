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
}
