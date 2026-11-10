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

    /// Every combination the fallback reads: Apple speech on the system or not, Whistle available or not, and
    /// Parakeet verified and runnable, verified but short of memory now, missing on a capable device, or too big.
    private var fallbackCases: [(name: String, policy: SpeechModelPolicy)] {
        var cases: [(String, SpeechModelPolicy)] = []
        for whistle in [true, false] {
            for (name, installation, physical, available) in [
                ("verified", ParakeetInstallation.verified, SpeechCapability.minimumPhysicalMemory, ParakeetMemory.beforeLoadBytes),
                ("verified, low headroom", .verified, SpeechCapability.minimumPhysicalMemory, ParakeetMemory.beforeLoadBytes - 1),
                ("missing", .missing, SpeechCapability.minimumPhysicalMemory, ParakeetMemory.beforeLoadBytes),
                ("checking", .checking, SpeechCapability.minimumPhysicalMemory, ParakeetMemory.beforeLoadBytes),
                ("too big", .missing, 3 << 30, ParakeetMemory.beforeLoadBytes),
            ] as [(String, ParakeetInstallation, UInt64, Int64)] {
                var facts = policy(installation)
                facts.whistleAvailable = whistle
                facts.physicalMemory = physical
                facts.availableMemory = available
                cases.append(("whistle \(whistle), parakeet \(name)", facts))
            }
        }
        var unlinked = policy(.missing)
        unlinked.whistleAvailable = false
        unlinked.parakeetLinked = false
        cases.append(("no whistle, parakeet not linked", unlinked))
        return cases
    }

    @Test func withAppleSpeechTheRecognizerIsTodaysSelection() {
        for (name, facts) in fallbackCases {
            for preference in SpeechModelPreference.allCases {
                #expect(facts.recognizer(preference: preference, platform: .iOS26)
                        == facts.selected(preference: preference) ?? .appleSpeech, "\(name), \(preference)")
            }
        }
    }

    /// Without Apple speech a device that can hold Parakeet falls back to it, so a Transcribe asks for its download (as
    /// Android does when its included model cannot run); one that cannot has no recognizer.
    @Test func withoutAppleSpeechTheFallbackIsParakeetIfItCanRunElseNone() {
        for (name, facts) in fallbackCases {
            for preference in SpeechModelPreference.allCases {
                let recognizer = facts.recognizer(preference: preference, platform: .iOS18)
                #expect(recognizer != .appleSpeech, "\(name)")
                if let selected = facts.selected(preference: preference) {
                    #expect(recognizer == selected, "only the fallback changes: \(name), \(preference)")
                }
            }
        }
        var facts = policy(.missing)
        #expect(facts.recognizer(platform: .iOS18) == .whistle, "Whistle stays the default before Parakeet is verified")
        facts.parakeetInstallation = .verified
        #expect(facts.recognizer(platform: .iOS18) == .parakeet)
        #expect(facts.recognizer(preference: .whistle, platform: .iOS18) == .whistle)
        facts.whistleAvailable = false
        facts.parakeetInstallation = .missing
        #expect(facts.recognizer(preference: .whistle, platform: .iOS18) == .parakeet, "missing Ultra asks for its download")
        #expect(facts.recognizer(platform: .iOS26) == .appleSpeech)
        facts.availableMemory = ParakeetMemory.beforeLoadBytes - 1
        #expect(facts.recognizer(platform: .iOS18) == .parakeet, "the run checks its headroom before it loads")
        facts.physicalMemory = 4 << 30
        #expect(facts.recognizer(platform: .iOS18) == nil)
        facts.physicalMemory = SpeechCapability.minimumPhysicalMemory
        facts.parakeetLinked = false
        #expect(facts.recognizer(platform: .iOS18) == nil)
    }
}
