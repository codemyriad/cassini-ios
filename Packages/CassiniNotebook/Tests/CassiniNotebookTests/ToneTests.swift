import Testing
@testable import CassiniNotebook

/// One tone per status, never colour alone: the text of each status says it too.
@Suite struct ToneTests {
    @Test func everyRowStatusHasItsTone() {
        let tones: [(LibraryRow.Status, Tone)] = [
            (.recording, .error), (.failed, .error), (.unplayable, .error), (.unreadable, .error),
            (.transcribing, .info), (.paused(atMs: 12_000), .warn),
            (.transcribed(speakers: 2, hasWords: true), .ok), (.transcribed(speakers: 0, hasWords: false), .ok),
            (.queued, .plain), (.newerFormat, .plain), (.audioOnly, .plain),
        ]
        for (status, tone) in tones { #expect(status.tone == tone, "\(status)") }
    }

    @Test func everyDocumentTrustHasItsTone() {
        let tones: [(DocumentTrust, Tone)] = [
            (.verified, .ok), (.notVerified, .warn), (.audioChanged, .warn), (.unreadable, .error), (.newerFormat, .error),
        ]
        for (trust, tone) in tones { #expect(trust.tone == tone, "\(trust)") }
    }

    @Test func everyBannerKindHasACatalogueTone() {
        for kind in BannerKind.allCases { #expect(Tone.allCases.contains(kind.tone)) }
    }
}
