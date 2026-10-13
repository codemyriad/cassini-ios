import Testing
import CassiniNotebook

@Suite struct MemoryPreflightTests {
    // ports: WavDecoderTest#durationCapAndMemoryGuard
    @Test func anHourNeedsAbout300MB() {
        #expect(MemoryPreflight.allows(durationMs: 3_600_000, availableBytes: 400 << 20))
        #expect(!MemoryPreflight.allows(durationMs: 3_600_000, availableBytes: 200 << 20))
    }

    // ports: InstalledEnginesTest#aLongClipThatDoesNotFitTheHeapGivesTheLowMemoryHint
    @Test func aLongClipThatDoesNotFitGivesTheLowMemoryHint() {
        let hour: Int64 = 60 * 60 * 1000
        #expect(MemoryPreflight.lowMemory(durationMs: hour, availableBytes: 100 << 20))
        #expect(!MemoryPreflight.lowMemory(durationMs: hour, availableBytes: 400 << 20))
        #expect(!MemoryPreflight.lowMemory(durationMs: 0, availableBytes: 0), "an unknown duration adds no hint")
        #expect(!MemoryPreflight.lowMemory(durationMs: hour, availableBytes: nil), "a system that does not tell adds none")
    }
}
