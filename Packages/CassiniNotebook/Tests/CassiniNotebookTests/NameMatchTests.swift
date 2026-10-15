import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct NameMatchTests {
    typealias F = VoiceFixtures
    let suggest = VoiceThresholds.campplus.suggest

    func voice(_ key: String, _ name: String, _ mean: [Float] = F.axis(0), model: String = F.model) -> SavedVoice {
        F.voice(key, name, mean, model: model)
    }

    // ports: NameMatchTest#normaliseStripsAccentsCaseAndSpaces
    @Test func normaliseStripsAccentsCaseAndSpaces() {
        #expect(NameMatch.normalise("Élodie") == "elodie")
        #expect(NameMatch.normalise("  ELODIE ") == "elodie")
        // A precomposed and a decomposed "é" are the same name.
        #expect(NameMatch.normalise("Jos\u{E9}") == NameMatch.normalise("Jose\u{301}"))
        #expect(NameMatch.normalise(" Anna \t Ricci ") == "anna ricci")
        #expect(NameMatch.normalise("Niccolò") == "niccolo")
        #expect(NameMatch.normalise("Straße") == "strasse")
        #expect(NameMatch.normalise("   ") == "")
    }

    // ports: NameMatchTest#anAccentedNameMatchesItsPlainForm
    @Test func anAccentedNameMatchesItsPlainForm() {
        let elodie = voice("e", "Élodie")
        #expect(NameMatch.samePersonCandidates("elodie", voices: [elodie]) == [elodie])
        #expect(NameMatch.samePersonCandidates(" ÉLODIE", voices: [elodie]) == [elodie])
        let plain = voice("p", "Elodie")
        #expect(NameMatch.samePersonCandidates("Élodie", voices: [plain]) == [plain])
    }

    // ports: NameMatchTest#aFirstNameMatchesTheFullName
    @Test func aFirstNameMatchesTheFullName() {
        let anna = voice("a", "Anna Ricci")
        #expect(NameMatch.samePersonCandidates("Anna", voices: [anna]) == [anna])
        #expect(NameMatch.samePersonCandidates("anna ricci", voices: [anna]) == [anna])
    }

    // ports: NameMatchTest#aFullNameDoesNotMatchAShorterSavedName
    @Test func aFullNameDoesNotMatchAShorterSavedName() {
        let anna = voice("a", "Anna")
        #expect(NameMatch.samePersonCandidates("Anna Ricci", voices: [anna]).isEmpty)
        #expect(NameMatch.samePersonCandidates("Anna", voices: [anna]) == [anna])
    }

    // ports: NameMatchTest#aPartOfAWordOrALaterWordIsNoMatch
    @Test func aPartOfAWordOrALaterWordIsNoMatch() {
        let voices = [voice("a", "Annalisa"), voice("b", "Maria Anna"), voice("c", "Ricci Anna")]
        #expect(NameMatch.samePersonCandidates("Anna", voices: voices).isEmpty)
        #expect(NameMatch.samePersonCandidates("  ", voices: voices).isEmpty)
    }

    // ports: NameMatchTest#theHighestScoreIsPicked
    @Test func theHighestScoreIsPicked() {
        let ricci = voice("r", "Anna Ricci"), bianchi = voice("b", "Anna Bianchi")
        let scores = [ricci.id: Float(0.61), bianchi.id: 0.40]
        #expect(NameMatch.samePerson("Anna", voices: [bianchi, ricci], scores: scores) == ricci)
    }

    // ports: NameMatchTest#aTieIsPickedAlphabetically
    @Test func aTieIsPickedAlphabetically() {
        let ricci = voice("r", "Anna Ricci"), bianchi = voice("b", "Anna Bianchi")
        #expect(NameMatch.samePerson("Anna", voices: [ricci, bianchi], scores: [ricci.id: 0.5, bianchi.id: 0.5]) == bianchi)
        // Without scores (no print) everything ties.
        #expect(NameMatch.samePerson("Anna", voices: [ricci, bianchi], scores: [:]) == bianchi)
        // An accent does not move a name in the order: "Élodie" sorts as "elodie".
        let elodie = voice("e", "Élodie Martin"), emma = voice("m", "Elodie Zanetti")
        #expect(NameMatch.samePerson("elodie", voices: [emma, elodie], scores: [:]) == elodie)
    }

    // ports: NameMatchTest#aScoredCandidateBeatsAnUnscoredOne
    @Test func aScoredCandidateBeatsAnUnscoredOne() {
        let ricci = voice("r", "Anna Ricci"), bianchi = voice("b", "Anna Bianchi")
        #expect(NameMatch.samePerson("Anna", voices: [bianchi, ricci], scores: [ricci.id: 0.1]) == ricci)
    }

    // ports: NameMatchTest#noCandidateNoPick
    @Test func noCandidateNoPick() {
        #expect(NameMatch.samePerson("Luca", voices: [voice("a", "Anna")], scores: [:]) == nil)
    }

    // ports: NameMatchTest#rankByScoreThenNameWithStaleVoicesLast
    @Test func rankByScoreThenNameWithStaleVoicesLast() throws {
        let voices = [
            voice("old", "Zeno", model: "another-model"),
            voice("low", "Bruno", F.near(0.30, 2)),
            voice("top", "Paolo", F.near(0.70, 1)),
            voice("tie2", "Carla", F.near(0.30, 3)),
            voice("old2", "Aldo", F.axis(0, dimension: 4)),
        ]
        let rows = NameMatch.rank(F.print(F.axis(0)), voices: voices, model: nil, suggest: suggest)
        #expect(rows.map(\.voice.id) == ["top", "low", "tie2", "old2", "old"].map(F.id))
        #expect(rows.map(\.stale) == [false, false, false, true, true])
        #expect(abs(try #require(rows[0].score) - 0.70) < 1e-5)
        #expect(rows[3].score == nil)
        #expect(rows[4].score == nil)
        #expect(rows.map(\.likely) == [true, false, false, false, false])
    }

    // ports: NameMatchTest#likelyNeedsTheSuggestThreshold
    @Test func likelyNeedsTheSuggestThreshold() throws {
        let anna = [voice("a", "Anna", F.near(0.50, 1))]
        let score = try #require(NameMatch.rank(F.print(F.axis(0)), voices: anna, model: nil, suggest: 1).first?.score)
        let at = NameMatch.rank(F.print(F.axis(0)), voices: anna, model: nil, suggest: score)
        #expect(try #require(at.first).likely)
        let below = NameMatch.rank(F.print(F.axis(0)), voices: [voice("a", "Anna", F.near(0.49, 1))], model: nil, suggest: suggest)
        #expect(try !#require(below.first).likely)
    }

    // ports: NameMatchTest#atMostOneRowIsLikely
    @Test func atMostOneRowIsLikely() {
        let voices = [voice("a", "Anna", F.near(0.90, 1)), voice("b", "Bruno", F.near(0.80, 2))]
        #expect(NameMatch.rank(F.print(F.axis(0)), voices: voices, model: nil, suggest: suggest).filter(\.likely).count == 1)
    }

    // ports: NameMatchTest#withoutAPrintTheListIsAlphabeticalAndNothingIsLikely
    @Test func withoutAPrintTheListIsAlphabeticalAndNothingIsLikely() {
        let voices = [voice("p", "paolo"), voice("s", "Zeno", model: "x"), voice("e", "Élodie"), voice("a", "Anna")]
        let rows = NameMatch.rank(nil, voices: voices, model: F.model, suggest: suggest)
        #expect(rows.map(\.voice.id) == ["a", "e", "p", "s"].map(F.id))
        #expect(rows.allSatisfy { $0.score == nil && !$0.likely })
    }

    // ports: NameMatchTest#noVoicesNoRows
    @Test func noVoicesNoRows() {
        #expect(NameMatch.rank(F.print(F.axis(0)), voices: [], model: nil, suggest: suggest).isEmpty)
    }
}
