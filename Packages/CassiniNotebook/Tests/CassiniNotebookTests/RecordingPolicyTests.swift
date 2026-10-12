import Foundation
import Testing
import CassiniNotebook

@Suite struct RecordingPolicyTests {
    typealias Decision = RecordingPolicy.Decision
    let minute: Int64 = 60_000
    var hour: Int64 { 60 * minute }
    let floor = Limits.minRecordingFreeBytes
    let pcm = RecordingPolicy.pcmBytesPerSecond
    let plenty: Int64 = 64 << 30

    /// Free bytes that leave exactly `ms` of recording at `rate`.
    func spaceFor(_ ms: Int64, rate: Int64? = nil) -> Int64 { floor + ms * (rate ?? pcm) / 1000 }

    func decide(_ usable: Int64, rate: Int64? = nil) -> Decision {
        RecordingPolicy.decide(usableBytes: usable, bytesPerSecond: rate ?? pcm)
    }

    // ports: RecordingPolicyTest#theNominalRatesAreOpus48AndAac32Kbps
    @Test func theNominalRateIs48kHz16BitMonoPCMAndTheFloorIs200MiB() {
        #expect(pcm == 48_000 * 2)
        #expect(floor == 200 * 1024 * 1024)
        #expect(RecordingPolicy.finishBytesPerSecond == 128_000 / 8)
    }

    // ports: RecordingPolicyTest#plentyOfSpaceContinues
    @Test func plentyOfSpaceContinues() {
        #expect(decide(plenty) == .continue)
    }

    // ports: RecordingPolicyTest#storageLowStartsAtFifteenMinutesOfSpace
    @Test func storageLowStartsAtFifteenMinutesOfSpace() {
        #expect(decide(spaceFor(15 * minute)) == .storageLow(minutes: 15))
        #expect(decide(spaceFor(15 * minute) + pcm / 1000 + 1) == .continue)
        #expect(decide(spaceFor(12 * minute)) == .storageLow(minutes: 10))
        #expect(decide(spaceFor(minute)) == .storageLow(minutes: 5))
    }

    // ports: RecordingPolicyTest#theFloorItselfStillRecordsAndOneByteLessStops
    @Test func theFloorItselfStillRecordsAndOneByteLessStops() {
        #expect(decide(floor) == .storageLow(minutes: 5))
        #expect(decide(floor - 1) == .stopForSpace)
        #expect(decide(0) == .stopForSpace)
    }

    // ports: RecordingPolicyTest#theSameBytesLastLongerForAac
    @Test func theSameBytesLastLongerAtASlowerRate() {
        let bytes = spaceFor(10 * minute)
        #expect(decide(bytes) == .storageLow(minutes: 10))
        #expect(decide(bytes, rate: pcm * 2 / 3) == .storageLow(minutes: 15))
        #expect(decide(spaceFor(16 * minute, rate: pcm / 2), rate: pcm / 2) == .continue)
    }

    /// ports: RecordingPolicyTest#aLongRecordingStopsOnlyAtTheStorageFloor
    /// A synthetic recording with 16 GB free, decided once a minute as the file grows: it never stops for time, warns
    /// only in the last 15 min of space, and stops only at the floor (about 46 h at the PCM rate).
    @Test func aLongRecordingStopsOnlyAtTheStorageFloor() {
        let start = floor + 16_000_000_000
        var stoppedAt: Int64 = -1, warnedAt: Int64 = -1, elapsed: Int64 = 0
        loop: while elapsed <= 60 * hour {
            let usable = start - elapsed / 1000 * pcm
            switch decide(usable) {
            case .continue: #expect(warnedAt == -1)
            case .storageLow: if warnedAt < 0 { warnedAt = elapsed }
            case .stopForSpace: stoppedAt = elapsed; break loop
            }
            elapsed += minute
        }
        let runsOutAt = 16_000_000_000 / pcm * 1000
        #expect(stoppedAt > 40 * hour)
        #expect((runsOutAt...runsOutAt + minute).contains(stoppedAt))
        #expect((runsOutAt - 16 * minute...runsOutAt - 14 * minute).contains(warnedAt))
    }

    @Test func theFinishReserveRaisesTheFloor() {
        let reserve: Int64 = 1_000_000
        #expect(RecordingPolicy.decide(usableBytes: floor + reserve, bytesPerSecond: pcm, reserveBytes: reserve) == .storageLow(minutes: 5))
        #expect(RecordingPolicy.decide(usableBytes: floor + reserve - 1, bytesPerSecond: pcm, reserveBytes: reserve) == .stopForSpace)
        #expect(RecordingPolicy.finishReserve(elapsedMs: 3_600_000) == 3600 * RecordingPolicy.finishBytesPerSecond)
    }

    @Test func theRateIsNominalForTenSecondsThenMeasured() {
        #expect(RecordingPolicy.bytesPerSecond(fileBytes: 0, elapsedMs: 0) == pcm)
        #expect(RecordingPolicy.bytesPerSecond(fileBytes: 5_000_000, elapsedMs: 9_999) == pcm)
        #expect(RecordingPolicy.bytesPerSecond(fileBytes: 1_000_000, elapsedMs: 10_000) == 100_000)
        // A file that did not grow (yet) keeps the nominal rate.
        #expect(RecordingPolicy.bytesPerSecond(fileBytes: 0, elapsedMs: 60_000) == pcm)
    }

    @Test func aCheckCountsTheCaptureAndTheFinishCopy() {
        let elapsed: Int64 = 60 * minute
        let fileBytes = 3600 * pcm
        let reserve = RecordingPolicy.finishReserve(elapsedMs: elapsed)
        let perSecond = pcm + RecordingPolicy.finishBytesPerSecond
        let check = RecordingPolicy.check(usableBytes: floor + reserve + 30 * 60 * perSecond, fileBytes: fileBytes, elapsedMs: elapsed)
        #expect(check.space.spaceMs == 30 * minute)
        #expect(check.decision == .continue)
        let atFloor = RecordingPolicy.check(usableBytes: floor + reserve - 1, fileBytes: fileBytes, elapsedMs: elapsed)
        #expect(atFloor.decision == .stopForSpace)
        #expect(atFloor.space.spaceMs == 0)
    }

    /// Fake storage that never shrinks: 100 h captured, no stop and no warning.
    @Test func aHundredHourRecordingWithPlentyOfSpaceNeverStops() {
        for hours: Int64 in [1, 2, 3, 36, 100] {
            let elapsed = hours * hour
            let check = RecordingPolicy.check(usableBytes: plenty, fileBytes: elapsed / 1000 * pcm, elapsedMs: elapsed)
            #expect(check.decision == .continue)
        }
    }
}
