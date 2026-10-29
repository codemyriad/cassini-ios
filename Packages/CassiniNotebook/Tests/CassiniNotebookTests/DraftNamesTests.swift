import Foundation
import Testing
@testable import CassiniNotebook

/// Android's CheckpointNamesTest: the `live` and `rejected` members of `names.json` and the reducers that change a
/// draft's names. Voice ids are UUIDs on iOS (`VoiceFixtures.id`), so "luca" stands for `F.id("luca")`.
@Suite struct DraftNamesTests {
    typealias F = VoiceFixtures

    let empty = DraftNames.empty
    let luca = F.id("luca"), anna = F.id("anna"), paolo = F.id("paolo")
    var names: [UUID: String] { [luca: "Luca", anna: "Anna Ricci", paolo: "Paolo"] }

    func auto(_ voice: UUID, _ score: Float = 0.8) -> LiveMatch { LiveMatch(voice, score, .auto) }
    func suggested(_ voice: UUID, _ score: Float = 0.6) -> LiveMatch { LiveMatch(voice, score, .suggested) }
    func confirmed(_ voice: UUID, _ score: Float = 0.6) -> LiveMatch { LiveMatch(voice, score, .confirmed) }

    func roundTrip(_ names: DraftNames) throws -> DraftNames {
        try JSONDecoder().decode(DraftNames.self, from: names.encoded())
    }

    func json(_ names: DraftNames) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: names.encoded()) as? [String: Any])
    }

    // MARK: Codec

    // ports: CheckpointNamesTest#liveAndRejectedRoundTrip
    @Test func liveAndRejectedRoundTrip() throws {
        let draft = DraftNames(labels: ["s1": "Élodie"], merges: ["s4": "s1"], remembered: ["s1": .saved(anna)],
                               automatic: ["s2": "Luca"], generation: 3,
                               live: ["s1": confirmed(anna, 0.61), "s2": auto(luca, 0.83), "s3": suggested(paolo)],
                               rejected: ["s3": [luca, anna]])
        let object = try json(draft)
        #expect(Set(object.keys) == DraftNames.keys.union(DraftNames.optionalKeys))
        #expect(try roundTrip(draft) == draft)
        // Voice, score and the state by name; rejected voices as an array in the order given.
        let text = try #require(String(data: draft.encoded(), encoding: .utf8))
        #expect(text.contains("\"s1\":{\"score\":0.61,\"state\":\"CONFIRMED\",\"voice\":\"\(anna.uuidString)\"}"))
        #expect(text.contains("\"s3\":[\"\(luca.uuidString)\",\"\(anna.uuidString)\"]"))
    }

    // ports: CheckpointNamesTest#emptyMembersAreNotWritten
    @Test func emptyMembersAreNotWritten() throws {
        #expect(Set(try json(DraftNames(labels: ["a": "Ada"])).keys) == DraftNames.keys)
    }

    // ports: CheckpointNamesTest#missingMembersReadAsEmpty
    @Test func missingMembersReadAsEmpty() throws {
        let decoded = try JSONDecoder().decode(DraftNames.self, from: Data(#"{"labels":{},"merges":{},"generation":2}"#.utf8))
        #expect(decoded.live.isEmpty)
        #expect(decoded.rejected.isEmpty)
        #expect(decoded.generation == 2)
    }

    // ports: CheckpointNamesTest#anUnknownStateIsRefused
    @Test func anUnknownStateIsRefused() {
        let text = #"{"labels":{},"merges":{},"live":{"s":{"voice":"\#(luca.uuidString)","score":0.5,"state":"MAYBE"}}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DraftNames.self, from: Data(text.utf8)) }
    }

    // MARK: confirm

    // ports: CheckpointNamesTest#yesLucaNamesRemembersAndConfirms
    @Test func yesLucaNamesRemembersAndConfirms() {
        let draft = DraftNames(generation: 2).applyLive(["s": suggested(luca, 0.62)], names: names)
        let after = draft.confirm("s", voice: luca, name: "Luca", generation: 2, score: 0.62)
        #expect(after.labels["s"] == "Luca")
        #expect(after.remembered["s"] == .saved(luca))
        #expect(after.live["s"] == confirmed(luca, 0.62))
        #expect(after.generation == 2)
        #expect(!after.openForLive("s"))
    }

    // ports: CheckpointNamesTest#confirmAfterForgetEveryoneDropsEarlierChoices
    @Test func confirmAfterForgetEveryoneDropsEarlierChoices() {
        let draft = DraftNames(generation: 1).confirm("a", voice: anna, name: "Anna Ricci", generation: 1, score: 0.7)
        let after = draft.confirm("b", voice: luca, name: "Luca", generation: 2, score: 0.6)
        #expect(after.remembered == ["b": .saved(luca)])
        #expect(after.generation == 2)
        // A confirmation needs its remember choice; the label stays.
        #expect(after.live["a"] == nil)
        #expect(after.labels["a"] == "Anna Ricci")
    }

    // ports: CheckpointNamesTest#confirmDropsAnotherSpeakersUnconfirmedMatchToTheSameVoice
    @Test func confirmDropsAnotherSpeakersUnconfirmedMatchToTheSameVoice() {
        var draft = empty.applyLive(["a": suggested(luca), "b": auto(paolo)], names: names)
        draft.automatic = ["a": "Luca"]
        let after = draft.confirm("b", voice: luca, name: "Luca", generation: 0, score: 0.6)
        #expect(after.live["a"] == nil)
        #expect(after.automatic["a"] == nil)
        #expect(after.automatic["b"] == nil)
    }

    // ports: CheckpointNamesTest#confirmClearsARejectionOfThatVoice
    @Test func confirmClearsARejectionOfThatVoice() {
        let after = empty.reject("s", voice: luca).reject("s", voice: anna)
            .confirm("s", voice: luca, name: "Luca", generation: 0, score: 0.5)
        #expect(after.rejected == ["s": [anna]])
        let again = empty.reject("s", voice: luca).confirm("s", voice: luca, name: "Luca", generation: 0, score: 0.5)
        #expect(again.rejected.isEmpty)
    }

    // MARK: reject

    // ports: CheckpointNamesTest#notLucaIsNeverSuggestedAgain
    @Test func notLucaIsNeverSuggestedAgain() {
        let draft = empty.applyLive(["s": suggested(luca)], names: names)
        let after = draft.reject("s", voice: luca, voiceName: "Luca")
        #expect(after.live["s"] == nil)
        #expect(after.rejected == ["s": [luca]])
        #expect(after.applyLive(["s": suggested(luca, 0.9)], names: names) == after)
        #expect(after.excluded(["s", "t"]) == ["s": [luca]])
    }

    // ports: CheckpointNamesTest#notLucaRemovesTheAutomaticName
    @Test func notLucaRemovesTheAutomaticName() {
        let draft = empty.applyLive(["s": auto(luca)], names: names)
        #expect(draft.automatic["s"] == "Luca")
        let after = draft.reject("s", voice: luca, voiceName: "Luca")
        #expect(after.automatic["s"] == nil)
        #expect(after.live["s"] == nil)
    }

    // ports: CheckpointNamesTest#notLucaAfterYesLucaReturnsToThePlaceholderAndEnrolsNothing
    @Test func notLucaAfterYesLucaReturnsToThePlaceholderAndEnrolsNothing() {
        let after = empty.confirm("s", voice: luca, name: "Luca", generation: 0, score: 0.6)
            .reject("s", voice: luca, voiceName: "Luca")
        #expect(after.labels["s"] == nil)
        #expect(after.remembered["s"] == nil)
        #expect(after.live["s"] == nil)
        #expect(after.openForLive("s"))
    }

    // ports: CheckpointNamesTest#notLucaKeepsAMatchToSomeoneElse
    @Test func notLucaKeepsAMatchToSomeoneElse() {
        let after = empty.applyLive(["s": suggested(anna)], names: names).reject("s", voice: luca, voiceName: "Luca")
        #expect(after.live["s"] == suggested(anna))
    }

    // ports: CheckpointNamesTest#aLabelTheUserTypedStaysWhenItIsAnotherName
    @Test func aLabelTheUserTypedStaysWhenItIsAnotherName() {
        let after = empty.rename("s", "Luca Bianchi").reject("s", voice: luca, voiceName: "Luca")
        #expect(after.labels["s"] == "Luca Bianchi")
    }

    // MARK: The race: the job works out a live round from the names it read, the user answers the card meanwhile

    // ports: CheckpointNamesTest#aLiveRoundAndNotLucaCommute
    @Test func aLiveRoundAndNotLucaCommute() throws {
        let before = empty.applyLive(["s": suggested(luca, 0.55), "t": auto(paolo)], names: names)
        let rounds: [[String: LiveMatch]] = [
            ["s": suggested(luca, 0.58), "t": auto(paolo)],
            ["s": auto(luca, 0.9)],
            ["s": suggested(anna), "t": suggested(luca)],
            [:],
        ]
        for round in rounds {
            let liveFirst = before.applyLive(round, names: names).reject("s", voice: luca, voiceName: "Luca")
            let userFirst = before.reject("s", voice: luca, voiceName: "Luca").applyLive(round, names: names)
            #expect(liveFirst == userFirst, "round \(round)")
            #expect(try #require(liveFirst.rejected["s"]).contains(luca))
            #expect(liveFirst.live["s"]?.voice != luca)
        }
    }

    // ports: CheckpointNamesTest#aLiveRoundAndYesLucaCommute
    @Test func aLiveRoundAndYesLucaCommute() {
        let before = DraftNames(generation: 5).applyLive(["s": suggested(luca, 0.55)], names: names)
        let rounds: [[String: LiveMatch]] = [
            ["s": suggested(luca, 0.58), "t": auto(paolo)],
            ["s": suggested(anna), "t": suggested(luca)],
            ["t": auto(luca)],
            [:],
        ]
        for round in rounds {
            let liveFirst = before.applyLive(round, names: names)
                .confirm("s", voice: luca, name: "Luca", generation: 5, score: 0.55)
            let userFirst = before.confirm("s", voice: luca, name: "Luca", generation: 5, score: 0.55)
                .applyLive(round, names: names)
            #expect(liveFirst == userFirst, "round \(round)")
            #expect(liveFirst.live["s"] == confirmed(luca, 0.55))
            #expect(liveFirst.remembered["s"] == .saved(luca))
        }
    }

    // ports: CheckpointNamesTest#aLiveRoundAndNotLucaAfterYesLucaCommute
    @Test func aLiveRoundAndNotLucaAfterYesLucaCommute() {
        // The job skips a confirmed speaker, so its round has no entry for it.
        let before = empty.confirm("s", voice: luca, name: "Luca", generation: 0, score: 0.6)
        let round = ["t": suggested(anna)]
        let liveFirst = before.applyLive(round, names: names).reject("s", voice: luca, voiceName: "Luca")
        let userFirst = before.reject("s", voice: luca, voiceName: "Luca").applyLive(round, names: names)
        #expect(liveFirst == userFirst)
    }

    // MARK: applyLive

    // ports: CheckpointNamesTest#aLiveRoundReplacesTheEarlierOne
    @Test func aLiveRoundReplacesTheEarlierOne() {
        let first = empty.applyLive(["a": auto(luca), "b": suggested(anna)], names: names)
        #expect(first.automatic == ["a": "Luca"])
        let second = first.applyLive(["b": auto(anna)], names: names)
        #expect(second.live == ["b": auto(anna)])
        #expect(second.automatic == ["b": "Anna Ricci"])
    }

    // ports: CheckpointNamesTest#aLiveRoundLeavesNamedConfirmedAndMergedSpeakersAlone
    @Test func aLiveRoundLeavesNamedConfirmedAndMergedSpeakersAlone() throws {
        let draft = try empty.rename("named", "Giulia").confirm("sure", voice: luca, name: "Luca", generation: 0, score: 0.7)
            .merge("gone", into: "named")
        let after = draft.applyLive([
            "named": auto(anna), "sure": auto(paolo), "gone": suggested(paolo), "other": suggested(luca),
            "free": suggested(paolo),
        ], names: names)
        #expect(after.live == ["sure": confirmed(luca, 0.7), "free": suggested(paolo)])
        #expect(after.automatic.isEmpty)
    }

    // ports: CheckpointNamesTest#onlyAutoAndSuggestedMatchesCount (iOS's LiveMatch has no NONE or REJECTED state)
    @Test func onlyAutoAndSuggestedMatchesCount() {
        #expect(empty.applyLive(["a": confirmed(luca, 0.9)], names: names) == empty)
    }

    // ports: CheckpointNamesTest#anAutoMatchToAnUnknownVoiceGetsNoAutomaticName
    @Test func anAutoMatchToAnUnknownVoiceGetsNoAutomaticName() {
        let gone = F.id("gone")
        let after = empty.applyLive(["s": auto(gone)], names: names)
        #expect(after.live["s"] == auto(gone))
        #expect(after.automatic["s"] == nil)
    }

    // ports: CheckpointNamesTest#excludedAddsVoicesConfirmedForOtherSpeakers
    @Test func excludedAddsVoicesConfirmedForOtherSpeakers() {
        let draft = empty.confirm("a", voice: luca, name: "Luca", generation: 0, score: 0.7).reject("b", voice: anna)
        #expect(draft.excluded(["a", "b", "c"]) == ["b": [anna, luca], "c": [luca]])
    }

    // MARK: rename and remember

    // ports: CheckpointNamesTest#renameWinsOverTheAutomaticName
    @Test func renameWinsOverTheAutomaticName() {
        let after = empty.applyLive(["s": auto(luca)], names: names).rename("s", "  Giulia ")
        #expect(after.labels["s"] == "Giulia")
        #expect(after.automatic["s"] == nil)
        #expect(after.live["s"] == nil)
        #expect(!after.openForLive("s"))
    }

    // ports: CheckpointNamesTest#aBlankOrPlaceholderNameReturnsToTheDefault
    @Test func aBlankOrPlaceholderNameReturnsToTheDefault() {
        let draft = empty.rename("s", "Giulia").remember("s", .new, generation: 0)
        for name in ["", "   ", "Speaker 3", "Voce 2"] {
            let after = draft.rename("s", name)
            #expect(after.labels["s"] == nil, "\(name)")
            #expect(after.remembered["s"] == nil, "\(name)")
            #expect(after.openForLive("s"), "\(name)")
        }
    }

    // ports: CheckpointNamesTest#renameKeepsAConfirmation
    @Test func renameKeepsAConfirmation() {
        let after = empty.confirm("s", voice: anna, name: "Anna", generation: 0, score: 0.7).rename("s", "Anna Ricci")
        #expect(after.live["s"] == confirmed(anna, 0.7))
        #expect(after.remembered["s"] == .saved(anna))
    }

    // ports: CheckpointNamesTest#rememberingAnotherVoiceEndsTheConfirmation
    @Test func rememberingAnotherVoiceEndsTheConfirmation() {
        let draft = empty.confirm("s", voice: anna, name: "Anna", generation: 0, score: 0.7)
        #expect(draft.remember("s", .new, generation: 0).live["s"] == nil)
        #expect(draft.remember("s", nil, generation: 0).live["s"] == nil)
        #expect(draft.remember("s", .saved(anna), generation: 0).live["s"] == confirmed(anna, 0.7))
    }

    // ports: CheckpointNamesTest#rememberFollowsTheGeneration
    @Test func rememberFollowsTheGeneration() {
        let draft = DraftNames(generation: 1).remember("a", .saved(anna), generation: 1).remember("b", .new, generation: 1)
        #expect(draft.remembered == ["a": .saved(anna), "b": .new])
        let after = draft.remember("c", .saved(luca), generation: 2)
        #expect(after.remembered == ["c": .saved(luca)])
        #expect(after.generation == 2)
        #expect(draft.remember("b", nil, generation: 1).remembered == ["a": .saved(anna)])
    }

    // MARK: merge

    // ports: CheckpointNamesTest#mergeDropsTheSourceState
    @Test func mergeDropsTheSourceState() throws {
        let draft = empty.applyLive(["a": auto(luca), "b": suggested(anna)], names: names)
            .rename("b", "Bruno").remember("b", .new, generation: 0).reject("a", voice: paolo)
        let after = try draft.merge("a", into: "b")
        #expect(after.merges == ["a": "b"])
        #expect(after.labels == ["b": "Bruno"])
        #expect(after.remembered == ["b": .new])
        #expect(after.automatic.isEmpty)
        #expect(after.live["a"] == nil)
        #expect(after.rejected.isEmpty)
        #expect(!after.openForLive("a"))
    }

    // ports: CheckpointNamesTest#mergeCanFreezeTheTargetsShownName
    @Test func mergeCanFreezeTheTargetsShownName() throws {
        let draft = empty.applyLive(["b": auto(luca)], names: names)
        #expect(try draft.merge("a", into: "b", targetLabel: "Luca").labels["b"] == "Luca")
        #expect(try draft.merge("a", into: "b").labels["b"] == nil)
    }

    // ports: CheckpointNamesTest#reducersFollowMerges
    @Test func reducersFollowMerges() throws {
        let draft = try empty.merge("a", into: "b")
        #expect(draft.rename("a", "Bruno").labels == ["b": "Bruno"])
        #expect(draft.reject("a", voice: luca).rejected == ["b": [luca]])
        #expect(throws: (any Error).self) { try draft.merge("a", into: "b") }
    }

    // MARK: Forget (iOS's reducers for VoicesStore's Forget and Forget everyone, Android's `forgetInDraft`)

    @Test func forgettingAVoiceDropsEverythingThatNamesIt() {
        let draft = empty.applyLive(["a": auto(luca), "b": suggested(anna)], names: names)
            .remember("c", .saved(luca), generation: 0).reject("d", voice: luca).reject("d", voice: paolo)
            .rename("e", "Luca")
        let after = draft.forgetting(luca)
        #expect(after.live == ["b": suggested(anna)])
        #expect(after.automatic.isEmpty)
        #expect(after.remembered.isEmpty)
        #expect(after.rejected == ["d": [paolo]])
        #expect(after.labels == ["e": "Luca"])
    }

    @Test func forgettingEveryoneKeepsOnlyTheLabelsAndMerges() throws {
        let draft = try empty.applyLive(["a": auto(luca)], names: names).confirm("b", voice: anna, name: "Anna", generation: 0, score: 0.7)
            .reject("c", voice: paolo).merge("d", into: "b")
        #expect(draft.forgettingEveryone(generation: 3)
                == DraftNames(labels: ["b": "Anna"], merges: ["d": "b"], generation: 3))
    }
}
