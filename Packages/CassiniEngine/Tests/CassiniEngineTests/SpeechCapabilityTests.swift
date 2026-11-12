import Testing
import CassiniEngine

struct SpeechCapabilityTests {
    /// What devices report (Device Farm, 2026-11-11): a 3 GB device at most 3072 MiB, the 4 GB iPhone 13 3665 MiB and
    /// the 4 GB iPhone 11 3854 MiB.
    @Test func fourGigabyteDevicesCanHoldParakeetAndThreeGigabyteOnesCannot() {
        let mib: UInt64 = 1 << 20
        #expect(!SpeechCapability.parakeetCapable(physicalMemory: 3072 * mib))
        #expect(SpeechCapability.parakeetCapable(physicalMemory: 3665 * mib))
        #expect(SpeechCapability.parakeetCapable(physicalMemory: 3854 * mib))
        #expect(SpeechCapability.minimumPhysicalMemory == 3328 * mib)
        #expect(!SpeechCapability.parakeetCapable(physicalMemory: 3328 * mib - 1))
        #expect(SpeechCapability.parakeetCapable(physicalMemory: 3328 * mib))
    }

    /// A job stored without a recognizer keeps the device's choice from when it was stored, under the 5 GiB limit of
    /// then: Parakeet on 6 and 8 GB devices, not on the 4 GB ones that get Parakeet today.
    @Test func jobsWithoutARecognizerKeepTheChoiceOfTheOldLimit() {
        let mib: UInt64 = 1 << 20
        for reported in [3072, 3665, 3854] as [UInt64] {
            #expect(!SpeechCapability.legacyJobsAreParakeets(physicalMemory: reported * mib), "\(reported) MiB")
        }
        #expect(!SpeechCapability.legacyJobsAreParakeets(physicalMemory: 5120 * mib - 1))
        #expect(SpeechCapability.legacyJobsAreParakeets(physicalMemory: 5120 * mib))
        #expect(SpeechCapability.legacyJobsAreParakeets(physicalMemory: 5632 * mib), "a 6 GB iPhone 14")
    }

    @Test func appleRequiresHardwareLocaleAndSupportedAssets() {
        for hardware in [false, true] {
            for locale in [false, true] {
                for assets in [ModelPartStatus.ready, .notDownloaded, .downloading(nil), .unsupported] {
                    let apple = AppleSpeechCapability(hardwareAvailable: hardware, localeSupported: locale, assets: assets)
                    let eligible = hardware && locale && assets != .unsupported
                    #expect(SpeechCapability.choose(linked: true, capable: false, apple: apple) == (eligible ? .appleSpeech : nil))
                    #expect(SpeechCapability.choose(linked: false, capable: true, apple: apple) == (eligible ? .appleSpeech : nil))
                    #expect(SpeechCapability.choose(linked: true, capable: true, apple: apple) == .parakeet)
                }
            }
        }
    }

    @Test func hardwareAndLocaleFailuresHaveDifferentExplanations() {
        #expect(AppleSpeechCapability(hardwareAvailable: false, localeSupported: false, assets: .unsupported).failure == .model)
        #expect(AppleSpeechCapability(hardwareAvailable: true, localeSupported: false, assets: .unsupported).failure == .unsupportedLanguage)
        #expect(AppleSpeechCapability(hardwareAvailable: true, localeSupported: true, assets: .unsupported).failure == .model)
        #expect(AppleSpeechCapability(hardwareAvailable: true, localeSupported: true, assets: .notDownloaded).failure == nil)
    }
}
