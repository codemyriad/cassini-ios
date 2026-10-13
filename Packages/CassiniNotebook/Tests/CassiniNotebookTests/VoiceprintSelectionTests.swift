import Foundation
import Testing
@testable import CassiniNotebook

/// Android's VoiceprintSelectionTest, where it applies on iOS. Android cuts each speaker's audio into bounded windows
/// and embeds them itself; on iOS FluidAudio's diarizer embeds every speaker, so the window cutting and capping have no
/// counterpart. What remains is the rule behind them: only the time a speaker talks alone counts as their speech
/// (`SpeakerAttribution.isolatedSeconds`, the print's `speechSeconds`), a speaker with too little of it is never
/// matched or remembered, and prints are normalised and compared by cosine.
@Suite struct VoiceprintSelectionTests {
    typealias F = VoiceFixtures

    private func turn(_ start: Double, _ end: Double, _ speaker: String) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, start: start, end: end)
    }

    // ports: VoiceprintSelectionTest#anotherSpeakersTurnIsCutOut
    @Test func anotherSpeakersTurnIsCutOut() {
        let turns = [turn(0, 10, "spk_1"), turn(4, 5, "spk_2"), turn(20, 30, "spk_2")]
        #expect(SpeakerAttribution.isolatedSeconds(speakerID: "spk_1", turns: turns) == 9)
        #expect(SpeakerAttribution.isolatedSeconds(speakerID: "spk_2", turns: turns) == 10)
    }

    // ports: VoiceprintSelectionTest#shortSegmentsAndQuietSpeakersAreDropped
    @Test func quietSpeakersAreNeverMatched() {
        let seconds = VoiceLibrary.minimumRememberSeconds
        let quiet = F.print("quiet", F.near(0.95), seconds: seconds - 0.1)
        let heard = F.print("heard", F.near(0.95, 2), seconds: seconds)
        let matches = VoiceMatcher.match(prints: [quiet, heard], voices: [F.voice("anna")], excluded: [:])
        #expect(matches["quiet"] == nil)
        #expect(matches["heard"]?.voiceID == F.id("anna"))
    }

    // ports: VoiceprintSelectionTest#windowsStayInsideTheAudio (no turns: no speech)
    @Test func withoutTurnsNobodySpeaks() {
        #expect(SpeakerAttribution.isolatedSeconds(speakerID: "spk_1", turns: []) == 0)
        #expect(SpeakerAttribution.isolatedSeconds(speakerID: "spk_1", turns: [turn(5, 5, "spk_1"), turn(.nan, 3, "spk_1")]) == 0)
    }

    // ports: VoiceprintSelectionTest#printsAreNormalisedAndCompared
    @Test func printsAreNormalisedAndCompared() throws {
        let a = try #require(VoiceMatcher.normalized([3, 4]))
        #expect(abs(try #require(VoiceMatcher.cosine(a, a)) - 1) < 1e-6)
        let b = try #require(VoiceMatcher.normalized([-4, 3]))
        #expect(abs(try #require(VoiceMatcher.cosine(a, b))) < 1e-6)
        #expect(VoiceMatcher.normalized([0, 0]) == nil)
        #expect(VoiceMatcher.normalized([.nan, 1]) == nil)
    }
}
