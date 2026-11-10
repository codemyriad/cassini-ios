import Testing
import CassiniEngine

/// The Library search's text view edits (an iOS extra: Android's field takes Search as an IME action).
@Suite struct LibrarySearchEditTests {
    @Test func searchTypedAfterTheTextSubmitsTheTextWithoutTheLineBreak() {
        #expect(LibrarySearchEdit(text: "Thursday\n", query: "Thursday\n") == .submit("Thursday"))
    }

    @Test func aBindingThatMissedEditsStillSubmitsWhatTheFieldHolds() {
        // The iPadOS 18 failure: the query stopped at "Thur" while the field took the rest and Search.
        #expect(LibrarySearchEdit(text: "Thursday\n", query: "Thur") == .submit("Thursday"))
    }

    @Test func everyKindOfLineBreakAnywhereSubmits() {
        #expect(LibrarySearchEdit(text: "Thu\nrsday", query: "") == .submit("Thursday"))
        #expect(LibrarySearchEdit(text: "Thursday\r\n", query: "") == .submit("Thursday"))
        #expect(LibrarySearchEdit(text: "Thursday\u{2028}", query: "") == .submit("Thursday"))
        #expect(LibrarySearchEdit(text: "\n", query: "") == .submit(""))
    }

    @Test func textTheQueryDoesNotHoldIsFollowed() {
        #expect(LibrarySearchEdit(text: "Thursday", query: "Thur") == .follow("Thursday"))
        #expect(LibrarySearchEdit(text: "", query: "Thur") == .follow(""))
    }

    @Test func anUnfinishedCompositionIsLeftAlone() {
        // A dead key or an input method: "^" is marked text until "e" makes it "ê". Following it would end the composition.
        #expect(LibrarySearchEdit(text: "caf^", query: "caf", composing: true) == .none)
        #expect(LibrarySearchEdit(text: "ni\nhao", query: "", composing: true) == .none)
        // Committed, it is followed like any other edit.
        #expect(LibrarySearchEdit(text: "cafê", query: "caf", composing: false) == .follow("cafê"))
    }

    @Test func textTheQueryHoldsChangesNothing() {
        #expect(LibrarySearchEdit(text: "Thursday", query: "Thursday") == .none)
        #expect(LibrarySearchEdit(text: "", query: "") == .none)
    }
}
