import Testing
import CassiniEngine

struct SpeechCapabilityTests {
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
