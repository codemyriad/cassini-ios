import Testing
import CassiniEngine

@Suite struct SpeechModelRowActionTests {
    @Test func activeOrPendingWorkCannotReopenConsent() {
        for installation: ParakeetInstallation in [.checking, .installing] {
            for status: ModelRowStatus in [.notDownloaded, .failed, .pending, .checking, .downloading(percent: 46)] {
                #expect(SpeechModelRowAction.parakeet(installation: installation, status: status, runnable: true) == .none)
            }
        }
        for status: ModelRowStatus in [.pending, .checking, .downloading(percent: 46)] {
            #expect(SpeechModelRowAction.parakeet(installation: .missing, status: status, runnable: true) == .none)
        }
    }

    @Test func retryChecksExistingFilesAndOnlyMissingFilesOfferDownload() {
        #expect(SpeechModelRowAction.parakeet(installation: .unavailable, status: .failed, runnable: true) == .verify)
        #expect(SpeechModelRowAction.parakeet(installation: .missing, status: .failed, runnable: true) == .download)
        #expect(SpeechModelRowAction.parakeet(installation: .missing, status: .notDownloaded, runnable: true) == .download)
        #expect(SpeechModelRowAction.parakeet(installation: .verified, status: .ready, runnable: false) == .none)
        #expect(SpeechModelRowAction.parakeet(installation: .verified, status: .ready, runnable: true) == .choose)
    }
}
