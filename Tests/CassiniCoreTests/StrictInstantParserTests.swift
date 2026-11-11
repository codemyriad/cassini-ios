import CassiniCore
import Foundation
import Testing

struct StrictInstantParserTests {
    @Test(arguments: [
        "2026-02-30T09:31:48Z", "2026-02-29T09:31:48Z", "1900-02-29T09:31:48Z",
        "2100-02-29T09:31:48Z", "2000-02-30T09:31:48Z", "2026-04-31T09:31:48Z",
        "0000-01-01T00:00:00Z", "2026-00-01T00:00:00Z", "2026-13-01T00:00:00Z",
        "2026-01-00T00:00:00Z", "2026-01-32T00:00:00Z",
        "2026-11-09T24:00:00Z", "2026-11-09T25:01:00Z", "2026-11-09T23:60:00Z",
        "2026-11-09T23:59:60Z", "2026-11-09T23:59:99Z"
    ])
    func impossibleGregorianDatesAndClockComponentsAreNeverNormalized(_ text: String) {
        #expect(CassiniDocument.parseInstant(text) == nil)
    }

    @Test(arguments: [
        "2026-11-09T09:31:48+24:00", "2026-11-09T09:31:48-24:00",
        "2026-11-09T09:31:48+99:00", "2026-11-09T09:31:48+12:60",
        "2026-11-09T09:31:48-00:60", "2026-11-09T09:31:48+23:99"
    ])
    func invalidRfc3339NumericOffsetsAreRejected(_ text: String) {
        // Python datetime.fromisoformat normalizes some offset-minute overflows; RFC3339 does not.
        // These are strict component tests, not claims that Python rejects every malformed offset.
        #expect(CassiniDocument.parseInstant(text) == nil)
    }

    @Test(arguments: [
        ("2000-02-29T23:59:59+05:45", "2000-02-29T18:14:59Z"),
        ("2024-02-29T00:00:00-03:30", "2024-02-29T03:30:00Z"),
        ("2026-01-01T00:00:00+23:59", "2025-12-31T00:01:00Z"),
        ("2026-12-31T23:59:59-23:59", "2027-01-01T23:58:59Z"),
        (" 2026-11-09t09:31:48.123456z \n", "2026-11-09T09:31:48.123456Z"),
        ("2026-11-09 09:31:48.250+00:00", "2026-11-09T09:31:48.250Z")
    ])
    func validLeapDatesOffsetBoundariesAndLegacyFormsKeepTheirInstant(text: String, reference: String) throws {
        let actual = try #require(CassiniDocument.parseInstant(text))
        let expected = try #require(CassiniDocument.parseInstant(reference))
        #expect(actual == expected)
    }

    @Test(arguments: ["0001-01-01T00:00:00Z", "1900-02-28T23:59:59Z", "2000-02-29T00:00:00Z", "9999-12-31T23:59:59Z"])
    func validGregorianYearAndCenturyBoundariesRemainReadable(_ text: String) {
        #expect(CassiniDocument.parseInstant(text) != nil)
    }

    @Test func submillisecondDistinctionsAndReferenceMicrosecondTruncationArePreserved() throws {
        let first = try #require(CassiniDocument.parseInstant("2026-11-09T09:31:48.000001Z"))
        let second = try #require(CassiniDocument.parseInstant("2026-11-09T09:31:48.000002Z"))
        #expect(first != second)
        #expect(abs(second.timeIntervalSince(first) - 0.000001) < 0.00000025)
        #expect(CassiniDocument.parseInstant("2026-11-09T09:31:48.123456789Z") ==
                CassiniDocument.parseInstant("2026-11-09T09:31:48.123456Z"))
        #expect(CassiniDocument.parseInstant("2026-11-09T09:31:48.999999999Z") ==
                CassiniDocument.parseInstant("2026-11-09T09:31:48.999999Z"))
    }
}
