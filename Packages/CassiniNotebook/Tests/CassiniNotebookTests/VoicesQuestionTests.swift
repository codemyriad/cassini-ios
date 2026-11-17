import Testing
import CassiniNotebook

@Suite struct VoicesQuestionTests {
    @Test func firstVisibleWritableMeetingRequiresMultiplePreparedSpeakersAndNoOverlay() {
        func ask(answered: Bool = false, count: Int? = 2, visible: Bool = true,
                 writable: Bool = true, restored: Bool = true, obstructed: Bool = false) -> Bool {
            VoicesQuestion.shouldAsk(answered: answered, speakerCount: count, visible: visible,
                writable: writable, overlayReady: restored, obstructed: obstructed)
        }
        #expect(ask())
        #expect(!ask(answered: true))
        #expect(!ask(count: nil))
        #expect(!ask(count: 0))
        #expect(!ask(count: 1))
        #expect(!ask(visible: false))
        #expect(!ask(writable: false))
        #expect(!ask(restored: false))
        #expect(!ask(obstructed: true))
    }
}
