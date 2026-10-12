import Testing
import CassiniNotebook

@Suite struct BatteryProjectionTests {
    private typealias Reading = BatteryProjection.Reading

    // ports: BatteryProjectionTest#estimatesFromMeasuredDischargeAndClampsAtZero
    @Test func estimatesFromMeasuredDischargeAndClampsAtZero() {
        var meter = BatteryProjection()
        #expect(meter.sample(Reading(elapsedMs: 0, percent: 80, charging: false, chargeMicroampHours: 4_000_000), remainingMs: 600_000).percentAfter == nil)
        #expect(meter.sample(Reading(elapsedMs: 60_000, percent: 79, charging: false, chargeMicroampHours: 3_950_000), remainingMs: 600_000).percentAfter == nil)
        #expect(meter.sample(Reading(elapsedMs: 120_000, percent: 79, charging: false, chargeMicroampHours: 3_900_000), remainingMs: 600_000).percentAfter == 69)
        #expect(meter.sample(Reading(elapsedMs: 120_000, percent: 79, charging: false, chargeMicroampHours: 3_900_000), remainingMs: 60_000_000).percentAfter == 0)
    }

    // ports: BatteryProjectionTest#chargingAndResumingNeedFreshMeasurements
    @Test func chargingAndResumingNeedFreshMeasurements() {
        var meter = BatteryProjection()
        _ = meter.sample(Reading(elapsedMs: 0, percent: 80, charging: false), remainingMs: 600_000)
        #expect(meter.sample(Reading(elapsedMs: 120_000, percent: 80, charging: true), remainingMs: 600_000).charging)
        #expect(meter.sample(Reading(elapsedMs: 600_000, percent: 78, charging: false), remainingMs: 600_000).percentAfter == nil)
        #expect(meter.sample(Reading(elapsedMs: 720_000, percent: 76, charging: false), remainingMs: 600_000).percentAfter == 66)
        var fresh = BatteryProjection()
        #expect(fresh.sample(Reading(elapsedMs: 720_000, percent: 76, charging: false), remainingMs: 600_000).percentAfter == nil)
    }

    // ports: BatteryProjectionTest#noDropOrUnknownEtaCannotProduceAProjection
    @Test func noDropOrUnknownTimeLeftCannotProduceAProjection() {
        var meter = BatteryProjection()
        _ = meter.sample(Reading(elapsedMs: 0, percent: 50, charging: false), remainingMs: 600_000)
        #expect(meter.sample(Reading(elapsedMs: 300_000, percent: 50, charging: false), remainingMs: 600_000).percentAfter == nil)
        #expect(meter.sample(Reading(elapsedMs: 400_000, percent: 49, charging: false), remainingMs: nil).percentAfter == nil)
    }

    @Test func iOSFivePercentStepsProjectOnceTheLevelDrops() {
        var meter = BatteryProjection()
        _ = meter.sample(Reading(elapsedMs: 0, percent: 85, charging: false), remainingMs: 1_800_000)
        #expect(meter.sample(Reading(elapsedMs: 300_000, percent: 85, charging: false), remainingMs: 1_800_000).percentAfter == nil)
        #expect(meter.sample(Reading(elapsedMs: 600_000, percent: 80, charging: false), remainingMs: 1_200_000).percentAfter == 70)
    }
}
