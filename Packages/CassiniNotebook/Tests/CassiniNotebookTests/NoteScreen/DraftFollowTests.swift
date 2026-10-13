import Testing
import CassiniNotebook

@Suite struct DraftFollowTests {
    // ports: ScreenBehaviourTest#newDraftTextKeepsTheProgressCardInView (the rule that scrolls the draft)
    @Test func aScrollAboveTheEndStopsFollowingAndBackAtTheEndStartsIt() {
        var follow = DraftFollow()
        #expect(follow.sticks, "new text follows from the start")
        follow.scrollEnded(atEnd: false)
        #expect(!follow.sticks)
        follow.scrollEnded(atEnd: true)
        #expect(follow.sticks)
    }

    // ports: ScreenBehaviourTest#newDraftTextKeepsTheProgressCardInViewOnA16By9Phone (the 160 dp draft space)
    @Test func theCardStaysFixedWhileTheDraftKeeps160Points() {
        #expect(DraftFollow.pinsCard(area: 0, card: 400), "fixed before the first measurement")
        #expect(DraftFollow.pinsCard(area: 700, card: 540))
        #expect(!DraftFollow.pinsCard(area: 700, card: 541), "a large font scale scrolls card and draft together")
    }

    @Test func theEndCountsWithinAFewPoints() {
        #expect(DraftFollow.isAtEnd(offset: 1_000, visibleHeight: 500, contentHeight: 1_500))
        #expect(DraftFollow.isAtEnd(offset: 995, visibleHeight: 500, contentHeight: 1_500))
        #expect(!DraftFollow.isAtEnd(offset: 900, visibleHeight: 500, contentHeight: 1_500))
        #expect(DraftFollow.isAtEnd(offset: 0, visibleHeight: 500, contentHeight: 200), "content that fits is at its end")
    }
}
