import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct SpeechModelPolicyTests {
    private func policy(_ installation: ParakeetInstallation = .missing) -> SpeechModelPolicy {
        SpeechModelPolicy(whistleAvailable: true, parakeetLinked: true,
            physicalMemory: SpeechCapability.minimumPhysicalMemory,
            availableMemory: ParakeetMemory.beforeLoadBytes,
            parakeetInstallation: installation, availableDiskBytes: .max,
            downloadPlan: ModelPlan.of { _ in false })
    }

    @Test func bundledModelWorksBeforeParakeetIsVerified() {
        for state in [ParakeetInstallation.missing, .checking, .installing] {
            let facts = policy(state)
            #expect(facts.selected() == .whistle)
            #expect(facts.selected(preference: .parakeet) == .whistle)
        }
        #expect(policy(.verified).selected() == .parakeet)
        #expect(policy(.verified).selected(preference: .whistle) == .whistle)
    }

    @Test func unsupportedOrLowMemoryParakeetNeverBecomesDefaultOrSuggested() {
        var facts = policy(.verified)
        facts.physicalMemory = 3 << 30
        #expect(facts.selected() == .whistle)
        facts.parakeetInstallation = .missing
        #expect(!facts.canSuggestParakeet)
        facts.physicalMemory = SpeechCapability.minimumPhysicalMemory
        facts.parakeetLinked = false
        #expect(!facts.canSuggestParakeet)
        facts.parakeetLinked = true
        facts.availableMemory = ParakeetMemory.beforeLoadBytes - 1
        #expect(!facts.canSuggestParakeet)
        facts.parakeetInstallation = .verified
        #expect(facts.selected() == .whistle)
        facts.whistleAvailable = false
        #expect(facts.selected() == nil)
        facts.availableMemory = nil // Same unknown-headroom rule as the existing native preflight.
        #expect(facts.selected() == .parakeet)
        #expect(facts.selected(preference: .whistle) == .parakeet)
    }

    @Test func suggestionUsesTheMissingSpeechPlanAndItsRealDiskRequirement() {
        var facts = policy()
        let speech = ModelPlan.of { _ in false }.missing.filter { $0.part == .speech }
        #expect(facts.downloadPlan.missing == speech)
        #expect(facts.downloadPlan.totalBytes == speech.reduce(0) { $0 + $1.downloadBytes })
        #expect(facts.downloadPlan.totalBytes != speech.flatMap(\.models).reduce(0) { $0 + $1.artifactBytes })
        facts.availableDiskBytes = facts.downloadPlan.requiredFreeBytes - 1
        #expect(!facts.canSuggestParakeet)
        facts.availableDiskBytes += 1
        #expect(facts.canSuggestParakeet)
        for state in [ParakeetInstallation.checking, .installing, .verified] {
            facts.parakeetInstallation = state
            #expect(!facts.canSuggestParakeet)
        }
        facts.parakeetInstallation = .missing
        facts.downloadPlan = ModelPlan([])
        #expect(!facts.canSuggestParakeet, "Never suggest a fictitious zero-byte install")
    }

    @Test func afterFirstWhistleAndDismissalArePersistedWithoutNagging() throws {
        var state = ParakeetSuggestionState()
        let facts = policy()
        #expect(state.shows(.settings, policy: facts))
        #expect(!state.shows(.afterWhistle, policy: facts))
        state.completed(recognizer: .parakeet, kind: .transcribe, succeeded: true)
        state.completed(recognizer: .whistle, kind: .transcribe, succeeded: false)
        state.completed(recognizer: .whistle, kind: .speakersOnly, succeeded: true)
        #expect(!state.shows(.afterWhistle, policy: facts))
        state.completed(recognizer: .whistle, kind: .transcribe, succeeded: true)
        #expect(state.shows(.afterWhistle, policy: facts))
        state.markAfterWhistlePresented()
        #expect(!state.shows(.afterWhistle, policy: facts))
        #expect(state.shows(.settings, policy: facts), "The one-time result prompt does not dismiss Settings")
        state.dismiss()
        state.completed(recognizer: .whistle, kind: .transcribeAgain, succeeded: true)
        let restored = try JSONDecoder().decode(ParakeetSuggestionState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
        #expect(!restored.shows(.settings, policy: facts))
        #expect(!restored.shows(.afterWhistle, policy: facts))
        #expect(!ParakeetSuggestionState(completedWhistle: true).shows(.afterWhistle, policy: policy(.verified)))
    }
}
