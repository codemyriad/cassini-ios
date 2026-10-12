import Foundation
import Testing
import CassiniNotebook

@Suite struct RecordingSpaceTests {
    typealias Approx = RecordingSpace.Approx
    let minute: Int64 = 60_000
    var hour: Int64 { 60 * minute }
    let floor = Limits.minRecordingFreeBytes
    let pcm = RecordingPolicy.pcmBytesPerSecond

    // ports: RecordingSpaceTest#plentyOfSpaceShowsTheSpaceInWholeHours
    @Test func plentyOfSpaceShowsTheSpaceInWholeHours() {
        let space = RecordingSpace.of(usableBytes: floor + 31 * 3600 * pcm + 1_000_000, bytesPerSecond: pcm)
        #expect(space.approx == Approx(hours: 31, minutes: 0))
    }

    // ports: RecordingSpaceTest#theEstimateHasNoTwoHourClamp
    @Test func theEstimateHasNoTwoHourClamp() {
        // 64 GB free gives about 185 hours of PCM, not 2 h.
        let space = RecordingSpace.of(usableBytes: floor + 64_000_000_000, bytesPerSecond: pcm)
        #expect(space.spaceMs == 64_000_000_000 * 1000 / pcm)
        #expect(space.approx == Approx(hours: 185, minutes: 0))
        // A free terabyte does not overflow, nor does a volume that does not say.
        #expect(RecordingSpace.of(usableBytes: floor + (1 << 40), bytesPerSecond: 1000).spaceMs == 1 << 40)
        #expect(RecordingSpace.of(usableBytes: .max, bytesPerSecond: pcm).spaceMs > 0)
    }

    // ports: RecordingSpaceTest#littleSpaceShowsMinutes
    @Test func littleSpaceShowsMinutes() {
        let space = RecordingSpace.of(usableBytes: floor + 40 * 60 * pcm, bytesPerSecond: pcm)
        #expect(space.spaceMs == 40 * minute)
        #expect(space.approx == Approx(hours: 0, minutes: 40))
    }

    // ports: RecordingSpaceTest#spaceBelowTheFloorIsNone
    @Test func spaceBelowTheFloorIsNone() {
        #expect(RecordingSpace.of(usableBytes: floor - 1, bytesPerSecond: pcm).spaceMs == 0)
        #expect(RecordingSpace.of(usableBytes: floor, bytesPerSecond: pcm).spaceMs == 0)
        #expect(RecordingSpace.of(usableBytes: floor + pcm, bytesPerSecond: pcm).spaceMs == 1000)
    }

    // ports: RecordingSpaceTest#aacGrowsSlowerSoTheSameSpaceLastsLonger
    @Test func aSlowerRateMakesTheSameSpaceLastLonger() {
        let bytes = floor + 60 * 60 * pcm
        #expect(RecordingSpace.of(usableBytes: bytes, bytesPerSecond: pcm).spaceMs == hour)
        #expect(RecordingSpace.of(usableBytes: bytes, bytesPerSecond: pcm * 2 / 3).spaceMs == 90 * minute)
    }

    // ports: RecordingSpaceTest#theFileLimitWinsWhenItComesFirst (iOS has no file limit: the finish reserve takes its place)
    @Test func theReserveComesOffTheSpace() {
        let reserve = 600 * pcm
        #expect(RecordingSpace.of(usableBytes: floor + 2 * reserve, bytesPerSecond: pcm, reserveBytes: reserve).spaceMs == 10 * minute)
        #expect(RecordingSpace.of(usableBytes: floor + reserve, bytesPerSecond: pcm, reserveBytes: reserve).spaceMs == 0)
        #expect(RecordingSpace.of(usableBytes: floor + reserve, bytesPerSecond: pcm, reserveBytes: -1).spaceMs == 10 * minute)
    }

    // ports: RecordingSpaceTest#roundingIsWholeHoursFromTwoHoursElseFiveMinutesDown
    @Test func roundingIsWholeHoursFromTwoHoursElseFiveMinutesDown() {
        #expect(RecordingSpace.approx(31 * hour + 59 * minute) == Approx(hours: 31, minutes: 0))
        #expect(RecordingSpace.approx(2 * hour) == Approx(hours: 2, minutes: 0))
        #expect(RecordingSpace.approx(2 * hour + 59 * minute) == Approx(hours: 2, minutes: 0))
        #expect(RecordingSpace.approx(2 * hour - 1) == Approx(hours: 1, minutes: 55))
        #expect(RecordingSpace.approx(99 * minute) == Approx(hours: 1, minutes: 35))
        #expect(RecordingSpace.approx(hour + 4 * minute) == Approx(hours: 1, minutes: 0))
        #expect(RecordingSpace.approx(14 * minute + 59_999) == Approx(hours: 0, minutes: 10))
        #expect(RecordingSpace.approx(5 * minute) == Approx(hours: 0, minutes: 5))
        #expect(RecordingSpace.approx(1000 * hour + 59 * minute) == Approx(hours: 1000, minutes: 0))
    }

    // ports: RecordingSpaceTest#theShortestHintIsFiveMinutes
    @Test func theShortestHintIsFiveMinutes() {
        #expect(RecordingSpace.approx(4 * minute + 59_999) == Approx(hours: 0, minutes: 5))
        #expect(RecordingSpace.approx(0) == Approx(hours: 0, minutes: 5))
        #expect(RecordingSpace.approx(-1) == Approx(hours: 0, minutes: 5))
        #expect(RecordingSpace.approx(0).totalMinutes == 5)
        #expect(Approx(hours: 1, minutes: 35).totalMinutes == 95)
    }

    // ports: RecordingSpaceTest#aRateOfZeroIsRefused
    @Test func aRateOfZeroIsRefused() async {
        await #expect(processExitsWith: .failure) {
            _ = RecordingSpace.of(usableBytes: Limits.minRecordingFreeBytes, bytesPerSecond: 0)
        }
    }
}
