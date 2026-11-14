import Testing
@testable import CassiniNotebook

struct MeetingTitleVisibilityTests {
    @Test(arguments: [74.0, 98, 113, 174, 215])
    func handsOffAtTheInsetAdjustedBoundary(_ inset: Double) {
        var title = MeetingTitleVisibility()
        #expect(title.scrolled(offset: -inset, topInset: inset) == nil)
        #expect(title.measured(bottom: 37) == true)
        #expect(title.scrolled(offset: 36.5 - inset, topInset: inset) == nil)
        #expect(title.isVisible)
        #expect(title.scrolled(offset: 37 - inset, topInset: inset) == false)
        #expect(!title.isVisible)
        #expect(title.scrolled(offset: 38 - inset, topInset: inset) == nil)
        #expect(title.scrolled(offset: 36 - inset, topInset: inset) == true)
    }

    @Test func openingAndClosingFindReevaluatesAnUnchangedOffset() {
        var title = MeetingTitleVisibility()
        #expect(title.scrolled(offset: -100, topInset: 113) == nil)
        #expect(title.measured(bottom: 37) == true)
        // Its bottom is still at outer y=137, but the opaque Find bar now covers that point.
        #expect(title.scrolled(offset: -100, topInset: 174) == false)
        #expect(!title.isVisible)
        #expect(title.scrolled(offset: -100, topInset: 215) == nil)
        #expect(title.scrolled(offset: -100, topInset: 113) == true)
        #expect(title.isVisible)
    }

    @Test func compensatingTheOffsetForANewInsetKeepsTheTitleVisible() {
        var title = MeetingTitleVisibility()
        _ = title.scrolled(offset: -113, topInset: 113)
        _ = title.measured(bottom: 37)
        #expect(title.scrolled(offset: -174, topInset: 174) == nil)
        #expect(title.isVisible)
    }

    @Test func aRecreatedReaderSynchronizesItsParentsPreviousCompactTitle() {
        var parentShowsHeader = false
        var title = MeetingTitleVisibility()
        _ = title.scrolled(offset: -113, topInset: 113)
        if let visible = title.measured(bottom: 37) { parentShowsHeader = visible }
        #expect(parentShowsHeader)
        #expect(title.measured(bottom: 37) == nil)
    }

    @Test func waitsForMeasurementAndReevaluatesChangedTitleHeight() {
        var title = MeetingTitleVisibility()
        #expect(title.scrolled(offset: -70, topInset: 113) == nil)
        #expect(title.isVisible)
        #expect(title.measured(bottom: 37) == false)
        #expect(title.measured(bottom: 70) == true)
        #expect(title.measured(bottom: 37) == false)
    }

    @Test func continuousScrollingPublishesOnlyVisibilityTransitions() {
        var title = MeetingTitleVisibility()
        _ = title.scrolled(offset: -113, topInset: 113)
        _ = title.measured(bottom: 37)
        var changes: [Bool] = []
        for distance in 0...100 {
            if let visible = title.scrolled(offset: Double(distance) - 113, topInset: 113) { changes.append(visible) }
        }
        for distance in (0...100).reversed() {
            if let visible = title.scrolled(offset: Double(distance) - 113, topInset: 113) { changes.append(visible) }
        }
        #expect(changes == [false, true])
    }
}
