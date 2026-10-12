import Foundation
import Testing
@testable import CassiniNotebook

/// Android's VoiceMatcherTest with the iOS thresholds (automatic 0.85, suggest 0.65, margin 0.12).
@Suite struct VoiceMatcherTests {
    typealias F = VoiceFixtures

    func match(_ prints: [String: [Float]], _ voices: [SavedVoice], excluded: [String: Set<UUID>] = [:]) -> [String: VoiceMatch] {
        VoiceMatcher.match(prints: prints.map { F.print($0.key, $0.value) }, voices: voices, excluded: excluded)
    }

    // ports: VoiceMatcherTest#cosineOfNormalisedVectorsIsTheDotProduct
    @Test func cosineOfNormalisedVectorsIsTheDotProduct() throws {
        #expect(abs(try #require(VoiceMatcher.cosine(F.near(0.8), F.axis(0))) - 0.8) < 1e-6)
        #expect(abs(try #require(VoiceMatcher.cosine(F.axis(1), F.axis(0)))) < 1e-6)
        #expect(VoiceMatcher.normalized([.nan, 0]) == nil)
        #expect(VoiceMatcher.normalized([0, 0]) == nil)
    }

    // ports: VoiceMatcherTest#scoreDecidesAutoSuggestionOrNothing
    @Test func scoreDecidesAutoSuggestionOrNothing() {
        let voices = [F.voice("anna")]
        #expect(match(["s": F.near(0.90)], voices)["s"]?.automatic == true)
        #expect(match(["s": F.near(0.75)], voices)["s"]?.automatic == false)
        #expect(match(["s": F.near(0.55)], voices)["s"] == nil)
    }

    // ports: VoiceMatcherTest#closeSecondPersonDemotesToSuggestion
    @Test func closeSecondPersonDemotesToSuggestion() throws {
        let bruno = try #require(VoiceMatcher.normalized([0.9, 0.1, 0, 0, 0, 0, 0, 0]))
        let result = try #require(match(["s": F.near(0.85)], [F.voice("anna"), F.voice("bruno", nil, bruno)])["s"])
        #expect(!result.automatic)
    }

    // ports: VoiceMatcherTest#onePersonNamesAtMostOneSpeaker
    @Test func onePersonNamesAtMostOneSpeaker() {
        let matches = match(["a": F.near(0.90, 1), "b": F.near(0.88, 2)], [F.voice("anna")])
        #expect(matches["a"]?.voiceID == F.id("anna"))
        // The rival speaker is as close, so even the best one is only suggested.
        #expect(matches["a"]?.automatic == false)
        #expect(matches["b"] == nil)
    }

    // ports: VoiceMatcherTest#secondSpeakerMayTakeAnotherPerson
    @Test func secondSpeakerMayTakeAnotherPerson() {
        let matches = match(["a": F.axis(0), "b": F.axis(1)], [F.voice("anna", nil, F.axis(0)), F.voice("bruno", nil, F.axis(1))])
        #expect(matches["a"]?.voiceID == F.id("anna"))
        #expect(matches["b"]?.voiceID == F.id("bruno"))
        #expect(matches["b"]?.automatic == true)
    }

    // ports: VoiceMatcherTest#voicesOfAnotherModelAreIgnored
    @Test func voicesOfAnotherModelAreIgnored() {
        #expect(match(["s": F.axis(0)], [F.voice("anna", nil, F.axis(0), model: "old")]).isEmpty)
    }

    // ports: VoiceMatcherTest#anExcludedVoiceIsNeverMatchedToThatSpeaker
    @Test func anExcludedVoiceIsNeverMatchedToThatSpeaker() {
        #expect(match(["s": F.near(0.95)], [F.voice("anna")], excluded: ["s": [F.id("anna")]]).isEmpty)
    }

    // ports: VoiceMatcherTest#anExclusionHoldsOnlyForItsOwnSpeaker
    @Test func anExclusionHoldsOnlyForItsOwnSpeaker() {
        let matches = match(["a": F.near(0.90, 1), "b": F.near(0.95, 2)], [F.voice("anna")], excluded: ["b": [F.id("anna")]])
        // Without the exclusion "b" would take Anna; with it "a" does, and "b" is no rival, so the match is automatic.
        #expect(matches["a"]?.voiceID == F.id("anna"))
        #expect(matches["a"]?.automatic == true)
        #expect(matches["b"] == nil)
    }

    // ports: VoiceMatcherTest#anExcludedPairIsNoRival
    @Test func anExcludedPairIsNoRival() throws {
        let bruno = try #require(VoiceMatcher.normalized([0.9, 0.1, 0, 0, 0, 0, 0, 0]))
        let voices = [F.voice("anna"), F.voice("bruno", nil, bruno)]
        #expect(match(["s": F.near(0.88)], voices)["s"]?.automatic == false)
        #expect(match(["s": F.near(0.88)], voices, excluded: ["s": [F.id("bruno")]])["s"]?.automatic == true)
    }

    // ports: VoiceMatcherTest#anEmptyExclusionChangesNothing
    @Test func anEmptyExclusionChangesNothing() {
        let voices = [F.voice("anna", nil, F.axis(0)), F.voice("bruno", nil, F.axis(1))]
        let prints = ["a": F.near(0.9, 2), "b": F.near(0.7, 3)]
        #expect(match(prints, voices, excluded: ["a": [], "x": [F.id("anna")]]) == match(prints, voices))
    }

    /// iOS: a print or a sample with less than six seconds of isolated speech is not compared.
    @Test func tooLittleSpeechIsNeverMatched() {
        let voices = [F.voice("anna")]
        #expect(VoiceMatcher.match(prints: [F.print("s", F.axis(0), seconds: 5.9)], voices: voices).isEmpty)
        #expect(VoiceMatcher.match(prints: [F.print("s", F.axis(0))], voices: [F.voice("anna", seconds: 2)]).isEmpty)
    }
}
