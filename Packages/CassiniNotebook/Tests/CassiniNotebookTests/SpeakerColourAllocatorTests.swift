import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct SpeakerColourAllocatorTests {
    @Test func saturatedForeignHintDoesNotReuseAnOccupiedSlot() {
        let maximum = SpeakerColourAllocator.maximum
        var allocator = SpeakerColourAllocator(["foreign": maximum, "Alex": 2])
        #expect(allocator.reserve("Casey") == 0)
        #expect(allocator.reserve("Devon") == 1)
        #expect(allocator.reserve("Emery") == 3)
        #expect(allocator.reserve("Alex") == 2)
        #expect(allocator.reserve("foreign") == maximum)
        #expect(Set(allocator.assignments.values).count == allocator.assignments.count)
    }

    @Test func fallbackSkipsSlotsHeldOnlyByHistoricalReservations() {
        let maximum = SpeakerColourAllocator.maximum
        var allocator = SpeakerColourAllocator(["foreign": maximum, "Alex": 3],
            reserving: ["Alex": 0, "Casey": 2])
        #expect(allocator.reserve("Alex") == 3, "current authored values win for their ID")
        #expect(allocator.reserve("Devon") == 1, "the earlier slot zero remains reserved")
        #expect(allocator.reserve("Emery") == 4, "both current and historical reservations are skipped")
    }

    @Test func reachingTheMaximumSwitchesToUnusedSlotsAndKeepsThemAcrossReload() {
        let maximum = SpeakerColourAllocator.maximum
        var allocator = SpeakerColourAllocator(["old": maximum - 1, "Alex": 0, "Casey": 2])
        #expect(allocator.reserve("last") == maximum)
        #expect(allocator.reserve("Devon") == 1)
        let stored = allocator.byteAssignments
        allocator = SpeakerColourAllocator(exactAssignments: stored)
        #expect(allocator.reserve("Emery") == 3)
        #expect(allocator.reserve("Devon") == 1)
    }

    @Test func exactAssignmentsKeepCanonicallyEquivalentSpeakerIDsSeparate() {
        let composed = "voice-\u{E9}", decomposed = "voice-e\u{301}"
        var allocator = SpeakerColourAllocator(exactAssignments: [Data(composed.utf8): 2, Data(decomposed.utf8): 8])
        #expect(allocator.reserve(composed) == 2)
        #expect(allocator.reserve(decomposed) == 8)
        #expect(allocator.byteAssignments.count == 2)
        #expect(allocator.reserve("new") == 9)
        let restored = SpeakerColourAllocator(exactAssignments: allocator.byteAssignments)
        #expect(restored.byteAssignments[Data(composed.utf8)] == 2)
        #expect(restored.byteAssignments[Data(decomposed.utf8)] == 8)
    }
}
