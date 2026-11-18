import Foundation
import Testing
@testable import Cassini

@MainActor struct Wave6CopyTests {
    @Test func compiledCatalogUsesHonestIOSExclusionAndOneQuestionSetupInEveryLanguage() {
        let keys = ["backup.phoneOnlyCard.close.a11y", "voices.setup.title", "voices.setup.body",
                    "voices.setup.enable", "voices.setup.privacy.phone", "voices.enroll.testPhrase"]
        for language in ["en", "it", "fr", "es", "pt-BR", "pt-PT"] {
            for key in keys {
                let value = Wave6Copy.template(key, language: language)
                #expect(!value.isEmpty && value != key)
                #expect(!value.localizedCaseInsensitiveContains("this phone only"))
            }
        }
        #expect(Wave6Copy.template("voices.setup.title", language: "en") == "Recognise people you name?")
        #expect(Wave6Copy.template("voices.setup.enable", language: "en") == "Remember voices")
    }
}
