import Testing
import CassiniEngine

@Suite struct StopSignalTests {
    @Test func aCancelReplacesAPauseButNotTheOtherWayRound() {
        let signal = StopSignal()
        #expect(signal.request == nil)
        signal.stop(.pause(.user))
        #expect(signal.request == .pause(.user))
        signal.stop(.pause(.system))
        #expect(signal.request == .pause(.system))
        signal.stop(.cancel)
        signal.stop(.pause(.user))
        #expect(signal.request == .cancel)
    }
}
